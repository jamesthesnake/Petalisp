;;;; © 2016-2019 Marco Heisig         - license: GNU AGPLv3 -*- coding: utf-8 -*-

(cl:in-package #:common-lisp-user)

(defpackage #:petalisp.ir-backend
  (:use
   #:common-lisp
   #:alexandria
   #:petalisp.core
   #:petalisp.ir)
  (:export
   #:make-ir-backend))

