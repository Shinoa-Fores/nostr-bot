;;commands.lisp
(in-package :nostr-bot)

(export 'process-command)

;; Run eval for Common Lisp expressions
(defun run-eval-command (expression)
  "Evaluate a Common Lisp expression and return the result or an error message."
  (handler-case
      (let* ((form (handler-case
                       (read-from-string expression)
                     (error (e)
                       (return-from run-eval-command
                         (format nil "Error parsing expression: ~a" e)))))
             (result (eval form)))
        (format nil "~a" result))
    (error (e)
      (format nil "Error evaluating expression: ~a" e))))

;; Process commands and return response
(defun process-command (content sender-pubkey)
  "Process the content for commands and return the response string or NIL if no command matches.
   SENDER-PUBKEY is the public key of the sender for access control."
  (cond
    ((search "eval" content :test #'char-equal)
     (format t "[INFO] EVAL command detected, parsing arguments...~%")
     (let ((clean-sender (trim sender-pubkey))
           (clean-owner (trim *owner-pubkey*)))
       (format t "[DEBUG] Sender pubkey: ~a~%" clean-sender)
       (format t "[DEBUG] Owner pubkey: ~a~%" clean-owner)
       (if (string-equal clean-sender clean-owner)
           (let* ((content-lower (string-downcase content))
                  (eval-pos (search "eval" content-lower))
                  (command-rest (if eval-pos
                                    (subseq content-lower eval-pos)
                                    content-lower))
                  (words (split " " (trim command-rest) :omit-nulls t)))
             (format t "[DEBUG] Parsed words: ~a~%" words)
             (if (and (>= (length words) 2)
                      (string-equal (first words) "eval"))
                 (let ((expression (str:join " " (rest words))))
                   (format t "[INFO] Evaluating expression: ~a~%" expression)
                   (run-eval-command expression))
                 "Error: eval command requires a Lisp expression (e.g., eval (+ 69 420))"))
           (progn
             (format t "[INFO] Unauthorized eval attempt by pubkey: ~a~%" sender-pubkey)
             "Error: eval command is restricted to the bot owner"))))
;; GM FREN!             
    ((search "gm" content :test #'char-equal)
     (format t "[INFO] GM detected, responding...~%")
     "gm fren!")
    (t
     (format t "[INFO] No command detected in content: ~a~%" content)
     nil)))
