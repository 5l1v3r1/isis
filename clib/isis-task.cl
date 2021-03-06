;;;  $RCSfile: isis-task.cl,v $ $Revision: 2.0 $ $Date: 90/05/04 15:22:15 $  
;;; -*- Mode:Lisp; Package:ISIS; Syntax:COMMON-LISP; Base:10; Lowercase:T -*-
;;; Coded by Robert Cooper
;;;
;;;
;;;      ISIS release V2.0, May 1990
;;;      Export restrictions apply
;;;
;;;      The contents of this file are subject to a joint, non-exclusive
;;;      copyright by members of the ISIS Project.  Permission is granted for
;;;      use of this material in unmodified form in commercial or research
;;;      settings.  Creation of derivative forms of this software may be
;;;      subject to restriction; obtain written permission from the ISIS Project
;;;      in the event of questions or for special situations.
;;;      -- Copyright (c) 1990, The ISIS PROJECT
;;;
;;;
;;; allegro-CL ISIS interface: task/thread support
;;;

(in-package "ISIS")         ;; Only part of the isis package actually.
(provide 'isis-task)

;;; EXPORTS
(export '(isis-task isis-mainloop
          isis-entry defun-isis-entry defun-callback
          isis-input isis-output isis-signal isis-chwait
          isis-input-sig isis-output-sig isis-signal-sig isis-chwait-sig
          sleep isis-timeout
          t-fork t-fork-urgent t-fork-msg t-fork-urgent-msg
          t-sig t-sig-all t-sig-urgent t-wait
          ))

;;; USE/IMPORTS
(use-package :multiprocessing)
(require 'process)
(use-package :ff)
(require 'foreign)

;;;
;;; Individual task suspension. Should be called within "without-scheduling".
;;;

(defun process-suspend (p)
  (process-add-arrest-reason p 'isis-wait))

;;; Trace around all process switches.
(defun advise-suspend ()
  (excl:advise process-suspend :around trace-switches nil
               (let ((p (car excl:arglist)))
                 (if (eq p *current-process*)
                     (prog2
                         (format t "<?~d?>" *isis-thread-id*)
                         :do-it
                       (format t "<!~d!>" *isis-thread-id*))
                     :do-it))))
;(advise-suspend)

(defun process-run (p)
  (process-revoke-arrest-reason p 'isis-wait))

;;; without-process-lock macro

(defmacro without-process-lock (lock-form &body body)
  (let ((lock-var (gensym)))
    `(let ((,lock-var ,@lock-form))
      (unwind-protect
         (progn
           (if (eq (process-lock-locker *isis-mutex*)
                   *current-process*)
               (mp:process-unlock ,lock-var)
               (format t
                "without-process-lock: Warning: *isis-mutex* not locked by me")
               )
           (progn ,@body))

        (if (not (eq (mp:process-lock-locker ,lock-var) *current-process*))
            (mp:process-lock ,lock-var))))))

;;;
;;; ISIS task management functions, callable from C.
;;;
;; Actually for ISIS purposes there will only ever be one lock
;; so mutex_alloc is not needed and there need be no arg to 
;; mutex_lock/unlock.
;; (Further, all C code is executed without signals hence no lisp process switches
;; will occur. So we could avoid grabbing isis-mutex until a process was likely
;; to leave the C world via an upcall into the lisp world. This could save time
;; for simple ISIS calls. See isis_thread_enter and isis_thread_exit in cl_task.c)

(defvar *isis-mutex*)

(defun isis-ticker ()
  "Kluge function needed to prod lisp scheduler"
  (loop
   (process-sleep 1)))

(defun isis-task-init ()
  (setq *isis-mutex* (make-process-lock :name 'isis-mutex))
  (process-run-function "ISIS-ticker" 'isis-ticker))

  ;; Ensure that all lisp processes get their own copy of *isis-thread-id*
; This doesn't work properly, and I don't need it.
;  (if (null (assoc '*isis-thread-id excl:*cl-default-special-bindings*))
;      (setq excl:*cl-default-special-bindings*
;            (acons 'isis::*isis-thread-id* '(quote unknown-thread)
;                   excl:*cl-default-special-bindings*))))


(defun-c-callable cl-mutex-lock ()
  (process-lock *isis-mutex*))

(defun-c-callable cl-mutex-unlock ()
  (process-unlock *isis-mutex*))

;;; Threads.
;;; The special variable *isis-thread-id* is locally bound in each 
;;; process to that process's thread id.

(defvar *isis-thread-id* 'unknown-thread)

(defun-c-callable cl-thread-self ()
  (if (eq *isis-thread-id* 'unknown-thread)
      (setq *isis-thread-id* (object-to-id *current-process*))
      *isis-thread-id*))

;;; Thread wait and signal just use the process run reasons mechanism. 

(defun-c-callable cl-thread-wait ((thread-id :unsigned-long))
  (without-scheduling
   (without-process-lock (*isis-mutex*)
     (process-suspend (id-to-object thread-id)))))

(defun-c-callable cl-thread-signal ((thread-id :unsigned-long))
  (process-run (id-to-object thread-id)))

;;; Thread initial function.

(defun initial-function (arg)
  (declare (special *isis-thread-id*))
  (let ((*isis-thread-id* (object-to-id *current-process*)))
    (setf (process-name *current-process*)
                        (format nil "isis-thread-~d" *isis-thread-id*))
    (unwind-protect
       (invoke arg)
      (if (eq (process-lock-locker *isis-mutex*) *current-process*)
          (process-unlock *isis-mutex*)))))

(defun-c-callable cl-thread-fork ((arg :unsigned-long))
  (process-run-function "isis-thread-??" #'initial-function arg))

(defun-c-callable cl-thread-free ((thread-id :unsigned-long))
  (delete-id thread-id))

(defun-c-callable cl-thread-cleanup ()
  (let ((locker (process-lock-locker *isis-mutex*)))
    (if (not (null locker))
        (process-unlock *isis-mutex* locker))))

;;; Select calls from ISIS.

(defun isis-select ()
  (if (zerop (isis-select-from-lisp))
      nil
      t))

(defun-c-callable cl-thread-wait-fun ()
  (process-wait "ISIS doing a select" 'isis-select))

(defun-c-callable cl-thread-yield ()
  (process-allow-schedule))

;;; User callable task functions
;;; In all cases where a routine and an argument would be passed in C
;;; In all cases where a routine and an argument would be passed in C
;;; its probably more convenient and efficient to use lisp closures.

(defun isis-task (handler name)
  (isis-task (register-isis-fun handler) name))

(defun isis-entry (entry handler &optional (name ""))
  (isis-entry-c entry
                (register-isis-fun handler)
                name))

(defmacro defun-callback (func args &body body)
  `(ff:defun-c-callable ,func ,args ,@body))

;;; Example:
;;(defun-isis-entry foo 3 (m)
;;  (print "foo called with message m"))

(defmacro defun-isis-entry (func entry (msg-arg) &body body)
  `(progn
    (defun-c-callable ,func ((,msg-arg :unsigned-long))
      ,@body)
    (isis-entry ,entry ',func (symbol-name ',func))
    ',func))


(defun isis-input (file-des handler &optional (arg 0))
  (isis-input-c file-des (register-isis-fun handler) arg))
(defun isis-output (file-des handler &optional (arg 0))
  (isis-output-c file-des (register-isis-fun handler) arg))
(defun isis-signal (signo handler &optional (arg 0))
  (isis-signal-c signo (register-isis-fun handler) arg))
(defun isis-chwait (handler &optional (arg 0))
  (isis-chwait-c (register-isis-fun handler) arg))

(defun isis-input-sig (file-des condition &optional (arg 0))
  (isis-input-sig-c file-des condition (object-to-id arg)))
(defun isis-output-sig (file-des condition &optional (arg 0))
  (isis-output-sig-c file-des condition (object-to-id arg)))
(defun isis-signal-sig (signo condition &optional (arg 0))
  (isis-signal-sig-c signo condition (object-to-id arg)))
(defun isis-chwait-sig (condition &optional (arg 0))
  (isis-chwait-sig-c condition (object-to-id arg)))

(defun isis-mainloop (routine &optional (arg 0))
  (isis-mainloop-c (register-isis-fun routine) arg))

(defun sleep (secs) ; Redefine standard sleep function to call into ISIS.
  (isis-sleep secs))

(defun isis-timeout (milliseconds routine &optional (arg 0))
  (isis-timeout-c milliseconds (register-isis-fun routine) arg 0))

(defun t-fork (routine &optional (arg 0))
  (isis-fork (register-isis-fun routine) arg 0))
(defun t-fork-urgent (routine &optional (arg 0))
  (isis-fork-urgent (register-isis-fun routine) arg 0))
(defun t-fork-msg (routine msg)
  (isis-fork (register-isis-fun routine) 0 msg))
(defun t-fork-urgent-msg (routine msg)
  (isis-fork-urgent (register-isis-fun routine) 0 msg))

(defun t-sig (condition value)
  (t-sig-c condition (object-to-id value)))
(defun t-sig-all (condition value)
  (t-sig-all-c condition (object-to-id value)))
(defun t-sig-urgent (condition value)
  (t-sig-urgent-c condition (object-to-id value)))

(defun t-wait (condition &optional (why ""))
  (id-to-object (t-wait-l condition why)))
  ;; Unfortunately we can't call free-slot on the id here since
  ;; we may have been t-sig-all'ed.
