;;;; © 2016-2023 Marco Heisig         - license: GNU AGPLv3 -*- coding: utf-8 -*-

(in-package #:petalisp.api)

(defun lazy-index-components (shape-designator &optional (axis 0))
  (let* ((shape (shape-designator-shape shape-designator))
         (rank (shape-rank shape)))
    (unless (<= 0 axis (1- rank))
      (error "~@<Invalid axis ~A for a shape with rank ~D.~:@>" axis rank))
    (lazy-ref
     (lazy-array-from-range (nth axis (shape-ranges shape)))
     shape
     (make-transformation
      :input-rank rank
      :output-mask (vector axis)))))

