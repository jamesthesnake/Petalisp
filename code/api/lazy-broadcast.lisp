;;;; © 2016-2023 Marco Heisig         - license: GNU AGPLv3 -*- coding: utf-8 -*-

(in-package #:petalisp.api)

(defun lazy-broadcast (&rest arrays)
  (values-list (lazy-broadcast-list-of-arrays arrays)))

(defun lazy-broadcast-list-of-arrays (list-of-arrays)
  (let* ((lazy-arrays (mapcar #'lazy-array list-of-arrays))
         (shapes (remove-duplicates (mapcar #'lazy-array-shape lazy-arrays) :test #'shape=))
         (broadcast-shape
           (trivia:match shapes
             ((list shape)
              shape)
             ((list* shapes)
              (let* ((vector-of-ranges (map 'vector #'shape-ranges shapes))
                     (number-of-shapes (length vector-of-ranges))
                     (ranges '()))
                (loop until (every #'null vector-of-ranges) do
                  (let ((range nil))
                    (loop for index below number-of-shapes do
                      (unless (null (aref vector-of-ranges index))
                        (let ((other-range (pop (aref vector-of-ranges index))))
                          (if (null range)
                              (setf range other-range)
                              (setf range (broadcast-ranges range other-range))))))
                    (push range ranges)))
                (make-shape (nreverse ranges))))))
         (alist
           (loop for shape in shapes
                 collect
                 (cons shape (make-broadcasting-transformation shape broadcast-shape)))))
    (values
     (loop for lazy-array in lazy-arrays
           collect
           (lazy-ref
            lazy-array
            broadcast-shape
            (cdr (assoc (lazy-array-shape lazy-array) alist :test #'shape=))))
     broadcast-shape)))

(defun broadcast-ranges (range-1 range-2)
  (cond ((size-one-range-p range-2) range-1)
        ((size-one-range-p range-1) range-2)
        ((= (range-size range-1)
            (range-size range-2))
         range-1)
        ((range= range-1 range-2) range-1)
        (t
         (error "~@<Cannot broadcast the ranges ~S and ~S.~:@>"
                range-1 range-2))))

(defun make-broadcasting-transformation
    (source-shape target-shape &optional (position (shape-rank source-shape)))
  "Returns a transformation that maps every element of TARGET-SHAPE to an
element of SOURCE-SHAPE.  In case TARGET-SHAPE has a higher rank than
SOURCE-SHAPE, insert additional axes at POSITION."
  (declare (shape source-shape target-shape) (rank position))
  ;; The terminology is a bit confusing here because the transformation
  ;; argument of LAZY-REF points "backwards", i.e., from values of the
  ;; target to values of the source.
  (let* ((input-ranges (shape-ranges target-shape))
         (input-rank (shape-rank target-shape))
         (output-ranges (shape-ranges source-shape))
         (output-rank (shape-rank source-shape))
         (input-mask (make-array input-rank :initial-element nil))
         (output-mask (make-array output-rank :initial-element nil))
         (scalings (make-array output-rank :initial-element 1))
         (offsets (make-array output-rank :initial-element 0))
         (delta (- input-rank output-rank)))
    (unless (<= position output-rank)
      (error  "~@<The broadcast position ~R is too large for the shape ~S with rank ~R.~:@>"
              position source-shape output-rank))
    (unless (<= output-rank input-rank)
      (error "~@<Cannot broadcast from rank ~R to rank ~R.~:@>"
             output-rank input-rank))
    ;; Determine the input mask.
    (loop for axis below input-rank
          for input-range in input-ranges
          do (when (size-one-range-p input-range)
               (setf (aref input-mask axis)
                     (range-start input-range))))
    ;; Process all axes up to POSITION.
    (loop for axis below position
          for input-range in input-ranges
          for output-range in output-ranges
          do (cond ((size-one-range-p output-range)
                    (setf (aref scalings axis)
                          0)
                    (setf (aref offsets axis)
                          (range-start output-range)))
                   ((range= input-range output-range)
                    (setf (aref output-mask axis)
                          axis))
                   (t
                    (error "~@<Cannot broadcast the range ~S to the range ~S.~:@>"
                           output-range input-range))))
    ;; Process all axes after POSITION.
    (loop for axis from position below output-rank
          for input-range in (nthcdr (+ position delta) input-ranges)
          for output-range in (nthcdr position output-ranges)
          do (assert (range= input-range output-range))
             (setf (aref output-mask axis)
                   (+ axis delta)))
    (make-transformation
     :input-mask input-mask
     :output-mask output-mask
     :scalings scalings
     :offsets offsets)))
