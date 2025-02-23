;;;; © 2016-2023 Marco Heisig         - license: GNU AGPLv3 -*- coding: utf-8 -*-

(in-package #:petalisp.ir)

(defstruct (program
            (:predicate programp)
            (:constructor make-program))
  ;; This program's unique task with zero predecessors.
  (initial-task nil)
  ;; This program's unique task that has zero successors.
  (final-task nil)
  ;; An list whose entries are conses of leaf buffers and their
  ;; corresponding lazy arrays.
  (leaf-alist '() :type list)
  ;; A list of all root buffers of the program, in the order they were
  ;; supplied.
  (root-buffers '() :type list)
  ;; A simple vector, mapping from task numbers to tasks.
  (task-vector #() :type simple-vector)
  ;; The number of buffers in the program.
  (number-of-buffers 0 :type (and unsigned-byte fixnum))
  ;; The number of kernels in the program.
  (number-of-kernels 0 :type (and unsigned-byte fixnum)))

(declaim (inline program-number-of-tasks))
(defun program-number-of-tasks (program)
  (declare (program program))
  (length (program-task-vector program)))

;;; A task is a collection of kernels that fully define a set of buffers.
;;; The rules for task membership are:
;;;
;;; 1. All kernels writing to a buffer B with task T have task T.
;;;
;;; 2. All buffers written to by a kernel K with task T have task T.
;;;
;;; 3. A buffer that is used by a kernel in T and that depends on a buffer
;;;    in T is also in T.
(defstruct (task
            (:predicate taskp)
            (:constructor make-task))
  (program '() :type program)
  ;; The tasks that must be completed before this task can run.
  (predecessors '() :type list)
  ;; The tasks that have this one as their predecessor.
  (successors '() :type list)
  ;; This task's kernels.
  (kernels '() :type list)
  ;; The buffers defined by this task.
  (defined-buffers '() :type list)
  ;; A number that is unique among all tasks in this program and less than
  ;; the number of tasks in the program.
  (number 0 :type (and unsigned-byte fixnum)))

;;; A buffer represents a set of memory locations big enough to hold one
;;; element of type ELEMENT-TYPE for each index of the buffer's shape.
;;; Each buffer is written to by zero or more kernels and read from zero or
;;; more kernels.
(defstruct (buffer
            (:predicate bufferp)
            (:constructor make-buffer))
  ;; The shape of this buffer.
  (shape nil :type shape)
  ;; The type code of all elements stored in this buffer.
  (ntype nil :type typo:ntype)
  ;; The depth of the corresponding lazy array of this buffer.
  (depth nil :type (and unsigned-byte fixnum))
  ;; An alist whose keys are kernels writing to this buffer, and whose
  ;; values are all store instructions from that kernel into this buffer.
  (writers '() :type list)
  ;; An alist whose keys are kernels reading from this buffer, and whose
  ;; values are all load instructions from that kernel into this buffer.
  (readers '() :type list)
  ;; The task that defines this buffer.
  (task nil :type (or null task))
  ;; An opaque object, representing the allocated memory.
  (storage nil)
  ;; A number that is unique among all buffers in this program and less
  ;; than the total number of buffers in this program.
  (number 0 :type (and unsigned-byte fixnum)))

(declaim (inline leaf-buffer-p))
(defun leaf-buffer-p (buffer)
  (null (buffer-writers buffer)))

(declaim (inline root-buffer-p))
(defun root-buffer-p (buffer)
  (null (buffer-readers buffer)))

(declaim (inline interior-buffer-p))
(defun interior-buffer-p (buffer)
  (not (or (leaf-buffer-p buffer)
           (root-buffer-p buffer))))

(declaim (inline buffer-size))
(defun buffer-size (buffer)
  (shape-size (buffer-shape buffer)))

(declaim (inline buffer-program))
(defun buffer-program (buffer)
  (declare (buffer buffer))
  (task-program (buffer-task buffer)))

(declaim (inline buffer-bits))
(defun buffer-bits (buffer)
  (* (typo:ntype-bits (buffer-ntype buffer))
     (shape-size (buffer-shape buffer))))

;;; A kernel represents a computation that, for each element in its
;;; iteration space, reads from some buffers and writes to some buffers.
(defstruct (kernel
            (:predicate kernelp)
            (:constructor make-kernel))
  (iteration-space nil :type shape)
  ;; An alist whose keys are buffers, and whose values are stencils reading
  ;; from that buffer.
  (sources '() :type list)
  ;; An alist whose keys are buffers, and whose values are all store
  ;; instructions referencing that buffer.
  (targets '() :type list)
  ;; A vector of instructions of the kernel, in top-to-bottom order.
  (instruction-vector #() :type simple-vector)
  ;; The task that contains this kernel.
  (task nil :type (or null task))
  ;; A slot that can be used by the backend to attach further information
  ;; to the kernel.
  (data nil)
  ;; A number that is unique among all the kernels in this program and less
  ;; than the total number of kernels in this program.
  (number 0 :type (and unsigned-byte fixnum)))

(declaim (inline kernel-program))
(defun kernel-program (kernel)
  (declare (kernel kernel))
  (task-program (kernel-task kernel)))

;;; The behavior of a kernel is described by its iteration space and its
;;; instructions.  The instructions form a DAG, whose leaves are load
;;; instructions or references to iteration variables, and whose roots are
;;; store instructions.
;;;
;;; The instruction number of an instruction is an integer that is unique
;;; among all instructions of the current kernel.  Instruction numbers are
;;; handed out in depth first order of instruction dependencies, such that
;;; the roots (store instructions) have the highest numbers and that the
;;; leaf nodes (load and iref instructions) have the lowest numbers.  After
;;; modifications to the instruction graph, the numbers have to be
;;; recomputed.
;;;
;;; Each instruction input is a cons cell, whose cdr is another
;;; instruction, and whose car is an integer denoting which of the multiple
;;; values of the cdr is being referenced.
(defstruct (instruction
            (:predicate instructionp)
            (:copier nil)
            (:constructor nil))
  (inputs '() :type list)
  ;; A number that is unique among all instructions of this kernel.
  (number 0 :type (and unsigned-byte fixnum)))

;;; A call instruction represents the application of a function to a set of
;;; values that are the result of other instructions.
(defstruct (call-instruction
            (:include instruction)
            (:predicate call-instruction-p)
            (:copier nil)
            (:constructor make-call-instruction (number-of-values fnrecord inputs)))
  (fnrecord nil :type typo:fnrecord)
  (number-of-values nil :type (integer 0 (#.multiple-values-limit))))

(defun call-instruction-function (call-instruction)
  (typo:fnrecord-function
   (call-instruction-fnrecord call-instruction)))

;;; We call an instruction an iterating instruction, if its behavior
;;; directly depends on the current element of the iteration space.
(defstruct (iterating-instruction
            (:include instruction)
            (:predicate iterating-instruction-p)
            (:copier nil)
            (:constructor nil)
            (:conc-name instruction-))
  (transformation nil :type transformation))

;;; An iref instruction represents an access to elements of the iteration
;;; space itself.  Its transformation is a mapping from the iteration space
;;; to a rank one space.  Its value is the single integer that is the
;;; result of applying the transformation to the current iteration space.
(defstruct (iref-instruction
            (:include iterating-instruction)
            (:predicate iref-instruction-p)
            (:copier nil)
            (:constructor make-iref-instruction
                (transformation))))

;;; A load instruction represents a read from main memory.  It returns a
;;; single value --- the entry of the buffer storage at the location
;;; specified by the current element of the iteration space and the load's
;;; transformation.
(defstruct (load-instruction
            (:include iterating-instruction)
            (:predicate load-instruction-p)
            (:copier nil)
            (:constructor %make-load-instruction
                (buffer transformation)))
  (buffer nil :type buffer))

;;; A stencil is a set of load instructions that all have the same buffer,
;;; output mask, scalings, and offsets that are off only by at most
;;; *STENCIL-MAX-RADIUS* from the center of the stencil (measured in steps
;;; of the corresponding range of the buffer being loaded from).  The
;;; center of a stencil is the average of the offsets of all its load
;;; instructions.

(declaim (unsigned-byte *stencil-max-radius*))
(defparameter *stencil-max-radius* 7)

(defstruct (stencil
            (:predicate stencilp)
            (:copier nil)
            (:constructor %make-stencil))
  ;; The center of a stencil is an array that contains the average of the
  ;; offsets of all its load instructions.
  (center nil :type simple-vector)
  (load-instructions nil :type (cons load-instruction list)))

(defun compute-stencil-center (load-instruction &rest more-load-instructions)
  (flet ((offsets (load-instruction)
           (transformation-offsets
            (load-instruction-transformation load-instruction))))
    (if (null more-load-instructions)
        (offsets load-instruction)
        (let* ((result (alexandria:copy-array (offsets load-instruction)))
               (count 1))
          (loop for load-instruction in more-load-instructions do
            (incf count)
            (let ((offsets (offsets load-instruction)))
              (assert (= (length offsets) (length result)))
              (loop for offset across offsets for index from 0 do
                (incf (aref result index) offset))))
          (loop for sum across result for index from 0 do
            (setf (aref result index)
                  (floor sum count)))
          result))))

(defun make-stencil (load-instructions)
  (%make-stencil
   :center (apply #'compute-stencil-center load-instructions)
   :load-instructions load-instructions))

(defun stencil-from-load-instruction (load-instruction)
  (declare (load-instruction load-instruction))
  (%make-stencil
   :center (compute-stencil-center load-instruction)
   :load-instructions (list load-instruction)))

;;; All stencil properties can be inferred from its first load instruction,
;;; so we generate those repetitive accessors with a macro.
(macrolet ((def (name (load-instruction) &body body)
             `(progn
                (declaim (inline ,name))
                (defun ,name (stencil)
                  (declare (stencil stencil))
                  (let ((,load-instruction (first (stencil-load-instructions stencil))))
                    ,@body)))))
  (def stencil-buffer (load-instruction)
    (load-instruction-buffer load-instruction))
  (def stencil-input-rank (load-instruction)
    (transformation-input-rank
     (load-instruction-transformation load-instruction)))
  (def stencil-output-rank (load-instruction)
    (transformation-output-rank
     (load-instruction-transformation load-instruction)))
  (def stencil-output-mask (load-instruction)
    (transformation-output-mask
     (load-instruction-transformation load-instruction)))
  (def stencil-scalings (load-instruction)
    (transformation-scalings
     (load-instruction-transformation load-instruction))))

(defun kernel-stencils (kernel buffer)
  (let ((entry (assoc buffer (kernel-sources kernel))))
    (etypecase entry
      (null '())
      (cons (cdr entry)))))

(defun make-load-instruction (kernel buffer transformation)
  (let ((load-instruction (%make-load-instruction buffer transformation)))
    (block add-load-instruction-to-kernel
      (symbol-macrolet ((stencils (alexandria:assoc-value (kernel-sources kernel) buffer)))
        ;; Try to add the load instruction to an existing stencil.
        (loop for stencil in stencils do
          (block try-next-stencil
            (when (and (equalp (stencil-output-mask stencil)
                               (transformation-output-mask transformation))
                       (equalp (stencil-scalings stencil)
                               (transformation-scalings transformation)))
              ;; Compute the new center of the stencil if that load instruction
              ;; was added.
              (let* ((ranges (shape-ranges (buffer-shape buffer)))
                     (load-instructions (list* load-instruction (stencil-load-instructions stencil)))
                     (center (apply #'compute-stencil-center load-instructions)))
                ;; Ensure that the new center is valid for all load
                ;; instructions, including the one we are trying to add.
                (loop for load-instruction in load-instructions do
                  (let* ((transformation (load-instruction-transformation load-instruction))
                         (offsets (transformation-offsets transformation)))
                    (loop for offset1 across offsets
                          for offset2 across center
                          for range in ranges
                          do (unless (<= (abs (- offset2 offset1))
                                         (* *stencil-max-radius* (range-step range)))
                               (return-from try-next-stencil)))))
                ;; If control reaches this point, we know that the new center
                ;; is valid.  We can now add the load instruction to that
                ;; stencil.
                (setf (stencil-center stencil) center)
                (setf (stencil-load-instructions stencil) load-instructions)
                (return-from add-load-instruction-to-kernel)))))
        ;; If control reaches this point, it wasn't possible to add
        ;; the load instruction to an existing stencil.  Create a
        ;; new stencil instead.
        (push (stencil-from-load-instruction load-instruction) stencils)))
    (push load-instruction (alexandria:assoc-value (buffer-readers buffer) kernel))
    load-instruction))

;;; A store instruction represents a write to main memory.  It stores its
;;; one and only input at the entry of the buffer storage specified by the
;;; current element of the iteration space and the store instruction's
;;; transformation.  A store instruction returns zero values.
(defstruct (store-instruction
            (:include iterating-instruction)
            (:predicate store-instruction-p)
            (:copier nil)
            (:constructor %make-store-instruction
                (inputs buffer transformation)))
  (buffer nil :type buffer))

(defun make-store-instruction (kernel input buffer transformation)
  (let ((store-instruction (%make-store-instruction (list input) buffer transformation)))
    (push store-instruction (alexandria:assoc-value (kernel-targets kernel) buffer))
    (push store-instruction (alexandria:assoc-value (buffer-writers buffer) kernel))
    store-instruction))

(defun store-instruction-input (store-instruction)
  (declare (store-instruction store-instruction))
  (first (store-instruction-inputs store-instruction)))

(defgeneric instruction-number-of-values (instruction)
  (:method ((call-instruction call-instruction))
    (call-instruction-number-of-values call-instruction))
  (:method ((iref-instruction iref-instruction))
    1)
  (:method ((load-instruction load-instruction))
    1)
  (:method ((store-instruction store-instruction))
    0))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Printing

(defmethod print-object ((program program) stream)
  (print-unreadable-object (program stream :type t :identity t)
    (format stream "~S" (program-task-vector program))))

(defmethod print-object ((task task) stream)
  (print-unreadable-object (task stream :type t :identity t)
    (format stream "~S" (task-defined-buffers task))))

(defmethod print-object ((buffer buffer) stream)
  (print-unreadable-object (buffer stream :type t :identity t)
    (format stream "~S ~S"
            (typo:ntype-type-specifier (buffer-ntype buffer))
            (buffer-shape buffer))))

(defmethod print-object ((kernel kernel) stream)
  (print-unreadable-object (kernel stream :type t :identity t)
    (format stream "~S"
            (kernel-iteration-space kernel))))

;;; This function is used during printing, to avoid excessive circularity.
(defun simplify-input (input)
  (destructuring-bind (value-n . instruction) input
    (cons value-n (instruction-number instruction))))

(defmethod print-object ((call-instruction call-instruction) stream)
  (print-unreadable-object (call-instruction stream :type t)
    (format stream "~S ~S ~S"
            (instruction-number call-instruction)
            (typo:fnrecord-function (call-instruction-fnrecord call-instruction))
            (mapcar #'simplify-input (instruction-inputs call-instruction)))))

(defmethod print-object ((load-instruction load-instruction) stream)
  (print-unreadable-object (load-instruction stream :type t)
    (format stream "~S ~S ~S"
            (instruction-number load-instruction)
            :buffer ;(load-instruction-buffer load-instruction)
            (instruction-transformation load-instruction))))

(defmethod print-object ((store-instruction store-instruction) stream)
  (print-unreadable-object (store-instruction stream :type t)
    (format stream "~S ~S ~S ~S"
            (instruction-number store-instruction)
            (simplify-input (first (instruction-inputs store-instruction)))
            :buffer ;(store-instruction-buffer store-instruction)
            (instruction-transformation store-instruction))))

(defmethod print-object ((iref-instruction iref-instruction) stream)
  (print-unreadable-object (iref-instruction stream :type t)
    (format stream "~S ~S"
            (instruction-number iref-instruction)
            (instruction-transformation iref-instruction))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Mapping Functions

(declaim (inline map-program-tasks))
(defun map-program-tasks (function program)
  (declare (program program))
  (loop for task across (program-task-vector program) do
    (funcall function task)))

(declaim (inline map-task-successors))
(defun map-task-successors (function task)
  (mapc function (task-successors task)))

(declaim (inline map-task-predecessors))
(defun map-task-predecessors (function task)
  (mapc function (task-predecessors task)))

(declaim (inline map-task-kernels))
(defun map-task-kernels (function task)
  (mapc function (task-kernels task)))

(declaim (inline map-task-defined-buffers))
(defun map-task-defined-buffers (function task)
  (mapc function (task-defined-buffers task)))

(declaim (inline map-program-buffers))
(defun map-program-buffers (function program)
  (declare (program program))
  (map-program-tasks
   (lambda (task)
     (map-task-defined-buffers function task))
   program))

(declaim (inline map-program-kernels))
(defun map-program-kernels (function program)
  (declare (program program))
  (map-program-tasks
   (lambda (task)
     (map-task-kernels function task))
   program))

(declaim (inline map-buffer-inputs))
(defun map-buffer-inputs (function buffer)
  (declare (function function)
           (buffer buffer))
  (loop for (kernel . nil) in (buffer-writers buffer) do
    (funcall function kernel))
  buffer)

(declaim (inline map-buffer-outputs))
(defun map-buffer-outputs (function buffer)
  (declare (function function)
           (buffer buffer))
  (loop for (kernel . nil) in (buffer-readers buffer) do
    (funcall function kernel))
  buffer)

(declaim (inline map-buffer-load-instructions))
(defun map-buffer-load-instructions (function buffer)
  (declare (function function)
           (buffer buffer))
  (loop for (nil . load-instructions) in (buffer-readers buffer) do
    (loop for load-instruction in load-instructions do
      (funcall function load-instruction)))
  buffer)

(declaim (inline map-buffer-store-instructions))
(defun map-buffer-store-instructions (function buffer)
  (declare (function function)
           (buffer buffer))
  (loop for (nil . store-instructions) in (buffer-writers buffer) do
    (loop for store-instruction in store-instructions do
      (funcall function store-instruction)))
  buffer)

(declaim (inline map-kernel-inputs))
(defun map-kernel-inputs (function kernel)
  (declare (function function)
           (kernel kernel))
  (loop for (buffer . nil) in (kernel-sources kernel) do
    (funcall function buffer))
  kernel)

(declaim (inline map-kernel-outputs))
(defun map-kernel-outputs (function kernel)
  (declare (function function)
           (kernel kernel))
  (loop for (buffer . nil) in (kernel-targets kernel) do
    (funcall function buffer))
  kernel)

(declaim (inline map-kernel-stencils))
(defun map-kernel-stencils (function kernel)
  (declare (function function)
           (kernel kernel))
  (loop for (nil . stencils) in (kernel-sources kernel) do
    (mapc function stencils))
  kernel)

(declaim (inline map-kernel-load-instructions))
(defun map-kernel-load-instructions (function kernel)
  (declare (function function)
           (kernel kernel))
  (loop for (nil . stencils) in (kernel-sources kernel) do
    (loop for stencil in stencils do
      (loop for load-instruction in (stencil-load-instructions stencil) do
        (funcall function load-instruction))))
  kernel)

(declaim (inline map-kernel-store-instructions))
(defun map-kernel-store-instructions (function kernel)
  (declare (function function)
           (kernel kernel))
  (loop for (nil . store-instructions) in (kernel-targets kernel) do
    (loop for store-instruction in store-instructions do
      (funcall function store-instruction)))
  kernel)

(declaim (inline map-instruction-inputs))
(defun map-instruction-inputs (function instruction)
  (declare (function function)
           (instruction instruction))
  (loop for (nil . input) in (instruction-inputs instruction) do
    (funcall function input)))

(defun map-buffers-and-kernels (buffer-fn kernel-fn root-buffers)
  (unless (null root-buffers)
    (map-program-tasks
     (lambda (task)
       (map-task-defined-buffers buffer-fn task)
       (map-task-kernels kernel-fn task))
     (task-program (buffer-task (first root-buffers))))))

(defun map-buffers (function root-buffers)
  (map-buffers-and-kernels function #'identity root-buffers))

(defun map-kernels (function root-buffers)
  (map-buffers-and-kernels #'identity function root-buffers))

(declaim (inline map-kernel-instructions))
(defun map-kernel-instructions (function kernel)
  (let ((vector (kernel-instruction-vector kernel)))
    (declare (simple-vector vector))
    (map nil function vector)))

(declaim (inline map-stencil-load-instructions))
(defun map-stencil-load-instructions (function stencil)
  (mapc function (stencil-load-instructions stencil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Do Macros

(macrolet ((def (name var thing mapper)
             `(defmacro ,name ((,var ,thing &optional result) &body body)
                (check-type ,var symbol)
                `(block nil
                   (,',mapper (lambda (,,var) ,@body) ,,thing)
                   ,result))))
  (def do-program-tasks task program map-program-tasks)
  (def do-task-successors successor task map-task-successors)
  (def do-task-predecessors predecessor task map-task-predecessors)
  (def do-task-kernels kernel task map-task-kernels)
  (def do-task-defined-buffers defined-buffer task map-task-defined-buffers)
  (def do-program-buffers buffer program map-program-buffers)
  (def do-program-kernels kernel program map-program-kernels)
  (def do-buffer-inputs kernel buffer map-buffer-inputs)
  (def do-buffer-outputs kernel buffer map-buffer-outputs)
  (def do-buffer-load-instructions load-instruction buffer map-buffer-load-instructions)
  (def do-buffer-store-instructions store-instruction buffer map-buffer-store-instructions)
  (def do-kernel-inputs buffer kernel map-kernel-inputs)
  (def do-kernel-outputs buffer kernel map-kernel-outputs)
  (def do-kernel-stencils stencil kernel map-kernel-stencils)
  (def do-kernel-load-instructions load-instruction kernel map-kernel-load-instructions)
  (def do-kernel-store-instructions store-instruction kernel map-kernel-store-instructions)
  (def do-stencil-load-instructions load-instruction stencil map-stencil-load-instructions)
  (def do-instruction-inputs input instruction map-instruction-inputs)
  (def do-kernel-instructions instruction kernel map-kernel-instructions))

;;; Apply FUNCTION to each list of non-leaf buffers that have the same
;;; shape and element type.
(defun map-program-buffer-groups (function program)
  (let ((buffers '()))
    (do-program-buffers (buffer program)
      (unless (leaf-buffer-p buffer)
        (push buffer buffers)))
    (setf buffers (stable-sort buffers #'< :key (alexandria:compose #'typo:ntype-index #'buffer-ntype)))
    (setf buffers (stable-sort buffers #'shape< :key #'buffer-shape))
    (loop until (null buffers) do
      (let* ((buffer (first buffers))
             (shape (buffer-shape buffer))
             (ntype (buffer-ntype buffer))
             (last buffers))
        ;; Locate the last cons cell whose CAR is a buffer with the same
        ;; shape and ntype.
        (loop for cdr = (cdr last)
              while (consp cdr)
              while (let* ((other-buffer (car cdr))
                           (other-shape (buffer-shape other-buffer))
                           (other-ntype (buffer-ntype other-buffer)))
                      (and (shape= shape other-shape)
                           (typo:ntype= ntype other-ntype)))
              do (setf last (cdr last)))
        ;; Destructively cut the list of buffers right after that last
        ;; cons.
        (let ((rest (cdr last)))
          (setf (cdr last) nil)
          (funcall function buffers)
          (setf buffers rest))))))

(defmacro do-program-buffer-groups ((buffers program &optional result) &body body)
  (check-type buffers symbol)
  `(block nil
     (map-program-buffer-groups (lambda (,buffers) ,@body) ,program)
     ,result))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Transforming Kernels and Buffers

(defgeneric transform-instruction-input (instruction transformation)
  (:method ((instruction instruction)
            (transformation transformation))
    (values))
  (:method ((instruction iterating-instruction)
            (transformation transformation))
    (setf (instruction-transformation instruction)
          (compose-transformations
           (instruction-transformation instruction)
           transformation))))

(defgeneric transform-instruction-output (instruction transformation)
  (:method ((instruction instruction)
            (transformation transformation))
    (values))
  (:method ((instruction iterating-instruction)
            (transformation transformation))
    (setf (instruction-transformation instruction)
          (compose-transformations
           transformation
           (instruction-transformation instruction)))))

(defun transform-buffer (buffer transformation)
  (declare (buffer buffer)
           (transformation transformation))
  (setf (buffer-shape buffer)
        (transform-shape (buffer-shape buffer) transformation))
  ;; After rotating a buffer, rotate all loads and stores referencing the
  ;; buffer to preserve the semantics of the IR.
  (map-buffer-store-instructions
   (lambda (store-instruction)
     (transform-instruction-output store-instruction transformation))
   buffer)
  (map-buffer-load-instructions
   (lambda (load-instruction)
     (transform-instruction-output load-instruction transformation))
   buffer)
  buffer)

(defun transform-kernel (kernel transformation)
  (declare (kernel kernel)
           (transformation transformation))
  (unless (identity-transformation-p transformation)
    (setf (kernel-iteration-space kernel)
          (transform-shape (kernel-iteration-space kernel) transformation))
    (let ((inverse (invert-transformation transformation)))
      (do-kernel-instructions (instruction kernel)
        (transform-instruction-input instruction inverse))))
  (do-kernel-stencils (stencil kernel)
    (setf (stencil-center stencil)
          (apply #'compute-stencil-center (stencil-load-instructions stencil)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Miscellaneous

(defun program-buffer (program buffer-number)
  (do-program-buffers (buffer program)
    (when (= (buffer-number buffer) buffer-number)
      (return-from program-buffer buffer)))
  (error "No buffer with number ~D in program ~S."
         buffer-number
         program))

(defun program-kernel (program kernel-number)
  (do-program-kernels (kernel program)
    (when (= (kernel-number kernel) kernel-number)
      (return-from program-kernel kernel)))
  (error "No kernel with number ~D in program ~S."
         kernel-number
         program))

(declaim (inline count-mapped-elements))
(defun count-mapped-elements (map-fn what)
  (let ((counter 0))
    (declare (type (and fixnum unsigned-byte) counter))
    (funcall
     map-fn
     (lambda (element)
       (declare (ignore element))
       (incf counter))
     what)
    counter))

(defun buffer-number-of-inputs (buffer)
  (declare (buffer buffer))
  (count-mapped-elements #'map-buffer-inputs buffer))

(defun buffer-number-of-outputs (buffer)
  (declare (buffer buffer))
  (count-mapped-elements #'map-buffer-outputs buffer))

(defun buffer-number-of-loads (buffer)
  (declare (buffer buffer))
  (count-mapped-elements #'map-buffer-load-instructions buffer))

(defun buffer-number-of-stores (buffer)
  (declare (buffer buffer))
  (count-mapped-elements #'map-buffer-store-instructions buffer))

(defun kernel-number-of-inputs (kernel)
  (declare (kernel kernel))
  (count-mapped-elements #'map-kernel-inputs kernel))

(defun kernel-number-of-outputs (kernel)
  (declare (kernel kernel))
  (count-mapped-elements #'map-kernel-outputs kernel))

(defun kernel-number-of-loads (kernel)
  (declare (kernel kernel))
  (count-mapped-elements #'map-kernel-load-instructions kernel))

(defun kernel-number-of-stores (kernel)
  (declare (kernel kernel))
  (count-mapped-elements #'map-kernel-store-instructions kernel))

(defun kernel-highest-instruction-number (kernel)
  (declare (kernel kernel))
  (let ((max 0))
    ;; This function exploits that the numbers are handed out in
    ;; depth-first order, starting from the leaf instructions.  So we know
    ;; that the highest instruction number must be somewhere among the
    ;; store instructions.
    (map-kernel-store-instructions
     (lambda (store-instruction)
       (alexandria:maxf max (instruction-number store-instruction)))
     kernel)
    max))

;;; This function is a very ad-hoc approximation of the cost of executing
;;; the kernel.
(defun kernel-cost (kernel)
  (max 1 (* (shape-size (kernel-iteration-space kernel))
            (kernel-highest-instruction-number kernel))))

(defun make-buffer-like-array (buffer)
  (declare (buffer buffer))
  (make-array-from-shape-and-ntype
   (buffer-shape buffer)
   (buffer-ntype buffer)))

(defun make-array-from-shape-and-ntype (shape ntype)
  (declare (shape shape) (typo:ntype ntype))
  (make-array
   (shape-dimensions shape)
   :element-type (typo:ntype-type-specifier ntype)))

(defun ensure-array-buffer-compatibility (array buffer)
  (declare (array array) (buffer buffer))
  (ensure-array-shape-ntype-compatibility
   array
   (buffer-shape buffer)
   (buffer-ntype buffer)))

(defun ensure-array-shape-ntype-compatibility (array shape ntype)
  (declare (array array) (shape shape) (typo:ntype ntype))
  (unless (= (shape-rank shape) (array-rank array))
    (error "Expected an array of rank ~D, got~% ~S~%"
           (array-rank array) array))
  (loop for range in (shape-ranges shape) for axis from 0 do
    (assert (= 0 (range-start range)))
    (assert (= 1 (range-step range)))
    (unless (= (array-dimension array axis) (range-size range))
      (error "Expected an array dimension of ~D in axis ~D, but got a dimension of ~D."
             (range-size range)
             axis
             (array-dimension array axis))))
  (unless (typo:ntype= (typo:array-element-ntype array)
                       (typo:upgraded-array-element-ntype ntype))
    (error "Not an array of type ~S: ~S"
           (array-element-type array)
           array))
  array)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; IR Modifications

(defun delete-kernel (kernel)
  (map-kernel-inputs
   (lambda (buffer)
     (setf (buffer-readers buffer)
           (remove kernel (buffer-readers buffer) :key #'car)))
   kernel)
  (map-kernel-outputs
   (lambda (buffer)
     (setf (buffer-writers buffer)
           (remove kernel (buffer-writers buffer) :key #'car)))
   kernel)
  (setf (kernel-instruction-vector kernel)
        #())
  (values))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Reasoning About Memory Locality
;;;
;;; If multiple consecutive loads or stores reference the same memory
;;; location, that memory reference can usually be served from a cache and
;;; is much faster.  Because data is eventually evicted from caches, it
;;; makes sense to rearrange buffers and kernel iteration spaces in such a
;;; way that the innermost loops of each kernel (i.e., the higher axes)
;;; have better data locality.
;;;
;;; The way we optimize for data locality is by introducing a notion of
;;; reuse potential.  Assuming a cache that is large enough to hold all
;;; elements referenced while traversing a particular axis of the iteration
;;; space, all loads with the same permutation and scalings but different
;;; offsets may lead to cache reuse.  We call this maximum number of
;;; attainable cache reuses the reuse potential.
;;;
;;; A reuse potential can be computed both for kernels and for buffers.  In
;;; both cases, we can then optimize the memory locality of the kernel or
;;; buffer by permuting its axes such that those with the hightes reuse
;;; potential appear last.

(defun kernel-reuse-potential (kernel)
  (let* ((rank (shape-rank (kernel-iteration-space kernel)))
         (result (make-array rank :initial-element 0)))
    (do-kernel-stencils (stencil kernel result)
      (dotimes (output-axis (stencil-output-rank stencil))
        (let ((input-axis (aref (stencil-output-mask stencil) output-axis))
              (test (differs-exactly-at output-axis))
              (alist '()))
          (unless (null input-axis)
            (dolist (load-instruction (stencil-load-instructions stencil))
              (let* ((transformation (load-instruction-transformation load-instruction))
                     (offsets (transformation-offsets transformation))
                     (entry (assoc offsets alist :test test)))
                (if (not entry)
                    (push (cons offsets 0) alist)
                    (incf (cdr entry)))))
            (loop for entry in alist do
              (incf (aref result input-axis)
                    (cdr entry)))))))))

(defun buffer-reuse-potential (buffer)
  (let* ((rank (shape-rank (buffer-shape buffer)))
         (result (make-array rank :initial-element 0)))
    (do-buffer-outputs (kernel buffer result)
      (dolist (stencil (kernel-stencils kernel buffer))
        (dotimes (output-axis rank)
          (let ((input-axis (aref (stencil-output-mask stencil) output-axis))
                (test (differs-exactly-at output-axis))
                (alist '()))
            (unless (null input-axis)
              (let ((size (range-size (shape-range (kernel-iteration-space kernel) input-axis))))
                (dolist (load-instruction (stencil-load-instructions stencil))
                  (let* ((transformation (load-instruction-transformation load-instruction))
                         (offsets (transformation-offsets transformation))
                         (entry (assoc offsets alist :test test)))
                    (if (not entry)
                        (push (cons offsets 0) alist)
                        (incf (cdr entry) size))))))
            (loop for entry in alist do
              (incf (aref result output-axis)
                    (cdr entry)))))))))

(defun differs-exactly-at (index)
  (lambda (a b)
    (let ((na (length a))
          (nb (length b)))
      (assert (= na nb))
      (loop for position below na
            for ea = (elt a position)
            for eb = (elt b position)
            always
            (if (= position index)
                (not (eql ea eb))
                (eql ea eb))))))

(defun reuse-optimizing-transformation (reuse-potential)
  "Takes a vector of single-precision floating-point numbers that describes
the potential for memory reuse along each axis, returns a transformation
that sorts all axes by increasing reuse potential."
  (make-transformation
   :output-mask
   (map 'vector #'car
        (stable-sort
         (loop for axis from 0 for rp across reuse-potential
               collect (cons axis rp))
         #'< :key #'cdr))))
