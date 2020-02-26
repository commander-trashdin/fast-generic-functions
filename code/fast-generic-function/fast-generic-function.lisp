(in-package #:sealable-metaobjects)

(defclass fast-method (potentially-sealable-standard-method)
  ((%inline-lambda
    :initarg .inline-lambda.
    :reader fast-method-inline-lambda
    :initform nil)))

(defclass fast-generic-function (sealable-standard-generic-function)
  ()
  (:default-initargs
   :method-class (find-class 'fast-method))
  (:metaclass funcallable-standard-class))

(defmethod validate-method-property
    ((method fast-method) (property (eql 'inlineable)))
  t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Expanding Effective Methods

(defmethod make-method-lambda :around
    ((fast-generic-function generic-function)
     (fast-method fast-method)
     lambda
     environment)
  (multiple-value-bind (method-lambda initargs)
      (call-next-method)
    (values
     method-lambda
     (list*
      '.inline-lambda.
      (compute-fast-method-inline-lambda fast-generic-function fast-method lambda environment)
      initargs))))

(defun compute-fast-method-inline-lambda
    (fast-generic-function fast-method lambda environment)
  (declare (ignore fast-method))
  (destructuring-bind (lambda-symbol lambda-list &rest body) lambda
    (assert (eql lambda-symbol 'lambda))
    (multiple-value-bind (required optional rest-var keyword allow-other-keys-p auxiliary)
        (parse-ordinary-lambda-list lambda-list)
      (let ((n-declarations (position-if-not (starts-with 'declare) body))
            (partially-flattened-lambda-list
              `(,@(lambda-list-variables
                   (unparse-ordinary-lambda-list
                    required optional rest-var keyword allow-other-keys-p '()))
                ,@(unparse-ordinary-lambda-list '() '() nil '() nil auxiliary))))
        (trivial-macroexpand-all:macroexpand-all
         `(lambda ,partially-flattened-lambda-list
            (declare (ignorable ,@(mapcar #'required-info-variable required)))
            ,@(subseq body 0 n-declarations)
            (block ,(block-name (generic-function-name fast-generic-function))
              ,@(subseq body n-declarations)))
         environment)))))

(defmethod fast-generic-function-lambda
    ((fast-generic-function fast-generic-function)
     (static-call-signature static-call-signature)
     &aux (applicable-methods
           (compute-applicable-methods
            fast-generic-function
            (static-call-signature-prototypes static-call-signature))))
  (multiple-value-bind (required optional rest-var keyword allow-other-keys-p)
      (parse-ordinary-lambda-list (generic-function-lambda-list fast-generic-function))
    ;; The keywords of the effective method are the union of the keywords
    ;; of the generic function and the keywords of each applicable method.
    (dolist (method applicable-methods)
      (multiple-value-bind (req opt rst m-keyword m-allow-other-keys-p)
          (parse-ordinary-lambda-list (method-lambda-list method))
        (declare (ignore req opt rst))
        (setf allow-other-keys-p (and allow-other-keys-p m-allow-other-keys-p))
        (dolist (keyword-info m-keyword)
          (pushnew keyword-info keyword :key #'keyword-info-keyword))))
    ;; We anonymize all bindings of the inline lambda, to prevent
    ;; accidental variable capture by any of the method lambdas.
    (let ((anonymized-lambda-list
            (anonymize-ordinary-lambda-list
             (unparse-ordinary-lambda-list
              required optional rest-var keyword allow-other-keys-p '()))))
      ;; Create the inline lambda.
      (trivial-macroexpand-all:macroexpand-all
       `(lambda ,anonymized-lambda-list
          (declare (ignorable ,@(lambda-list-variables anonymized-lambda-list)))
          ,@(loop for type in (static-call-signature-types static-call-signature)
                  for argument in anonymized-lambda-list
                  collect
                  `(declare (type ,type ,argument)))
          (let ((.gf. #',(generic-function-name fast-generic-function)))
            (declare (ignorable .gf.))
            #+sbcl(declare (sb-ext:disable-package-locks common-lisp:call-method))
            #+sbcl(declare (sb-ext:disable-package-locks common-lisp:make-method))
            #+sbcl(declare (sb-ext:disable-package-locks sb-pcl::check-applicable-keywords))
            (macrolet
                ;; SBCL introduces explicit keyword argument checking into
                ;; the effective method.  Since we do our own checking, we
                ;; can safely disable it.  However, we touch the relevant
                ;; variables to prevent unused variable warnings.
                (#+sbcl
                 (sb-pcl::check-applicable-keywords (&rest args)
                   (declare (ignore args))
                   `(progn sb-pcl::.valid-keys. sb-pcl::.keyargs-start. (values))))
              ,(wrap-in-call-method-macrolet
                (compute-effective-method
                 fast-generic-function
                 (generic-function-method-combination fast-generic-function)
                 applicable-methods)
                anonymized-lambda-list
                (or (class-name (generic-function-method-class fast-generic-function))
                    (find-class 'fast-method))))))))))

(defun wrap-in-call-method-macrolet (form lambda-list method-class)
  `(macrolet ((call-method (method &optional next-methods)
                (expand-call-method
                 method
                 next-methods
                 ',lambda-list
                 ',method-class)))
     ,(wrap-in-reinitialize-arguments form lambda-list)))

(defun wrap-in-reinitialize-arguments (form lambda-list)
  (let ((anonymized-lambda-list
          (anonymize-ordinary-lambda-list lambda-list)))
    `(flet ((reinitialize-arguments ,anonymized-lambda-list
              ,@(mapcar
                 (lambda (place value)
                   `(setf ,place ,value))
                 (lambda-list-variables lambda-list)
                 (lambda-list-variables anonymized-lambda-list))))
       (declare (ignorable #'reinitialize-arguments))
       (declare (inline reinitialize-arguments))
       ,form)))

(defun expand-call-method (method next-methods lambda-list method-class)
  (wrap-in-next-methods
   (call-inlineable-method
    (coerce-to-method method lambda-list method-class)
    lambda-list)
   next-methods
   method-class))

(defun coerce-to-method (method lambda-list method-class)
  (cond ((typep method 'fast-method)
         method)
        ((and (consp method)
              (eql (car method) 'make-method)
              (null (cddr method)))
         (make-instance method-class
           :lambda-list lambda-list
           :specializers (make-list (length (parse-ordinary-lambda-list lambda-list))
                                    :initial-element (find-class 't))
           :qualifiers '()
           :function #'values
           '.inline-lambda.
           `(lambda ,lambda-list
              (declare (ignorable ,@(lambda-list-variables lambda-list)))
              ,(second method))))
        (t
         (error "Cannot turn ~S into an inlineable method."
                method))))

(defun wrap-in-next-methods (form next-methods method-class)
  (if (null next-methods)
      `(flet ((next-method-p () nil)
              (call-next-method ()
                (no-next-method
                 .gf.
                 (specializer-prototype
                  (find-class ',method-class)))))
         (declare (ignorable #'next-method-p #'call-next-method))
         ,form)
      (wrap-in-next-methods
       `(flet ((next-method-p () t)
               (call-next-method (&rest args)
                 (unless (null args)
                   (apply #'reinitialize-arguments args))
                 (call-method ,(first next-methods) ,(rest next-methods))))
          (declare (ignorable #'next-method-p #'call-next-method))
          ,form)
       (rest next-methods)
       method-class)))

(defun call-inlineable-method (method lambda-list)
  (multiple-value-bind (g-required g-optional g-rest-var g-keyword)
      (parse-ordinary-lambda-list lambda-list)
    (multiple-value-bind (m-required m-optional m-rest-var m-keyword)
        (parse-ordinary-lambda-list (method-lambda-list method))
      ;; Assert that the method has arguments that are congruent to those
      ;; of the corresponding generic function.
      (assert (or (= (length g-required)
                     (length m-required))))
      (assert (= (length g-optional)
                 (length m-optional)))
      (when (null g-rest-var)
        (assert (null m-rest-var)))
      `(funcall
        ,(fast-method-inline-lambda method)
        ,@(mapcar #'required-info-variable g-required)
        ,@(loop for g-info in g-optional
                for m-info in m-optional
                append
                (let ((initform
                        `(if ,(optional-info-suppliedp g-info)
                             ,(optional-info-variable g-info)
                             ,(optional-info-initform m-info))))
                  (if (null (optional-info-suppliedp m-info))
                      `(,initform)
                      `(,initform ,(optional-info-suppliedp g-info)))))
        ,@(if (null m-rest-var)
              `()
              `(,g-rest-var))
        ,@(loop for m-info in m-keyword
                for g-info = (find (keyword-info-keyword m-info) g-keyword
                                   :key #'keyword-info-keyword)
                append
                (let ((initform
                        `(if ,(keyword-info-suppliedp g-info)
                             ,(keyword-info-variable g-info)
                             ,(keyword-info-initform m-info))))
                  (if (null (keyword-info-suppliedp m-info))
                      `(,initform)
                      `(,initform ,(keyword-info-suppliedp g-info)))))))))


