;;nostr-bot.asd
(asdf:defsystem #:nostr-bot
  :description "A Nostr bot for handling user defined commands"
  :author "Shinoa Fores [shinohai]"
  :depends-on (:websocket-driver :yason :babel :uiop :str :bip0340)
  :serial t
  :components ((:file "bot")
               (:file "commands")))
