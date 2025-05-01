# nostr-bot

<p align="center">
  A basic bot for nostr in common lisp.
</p>

<p align="center"><img src="docs/nostrbot.jpg?sanitize=true alt="nostrbot" width="250" height="250"></p>

This bot requires quicklisp and [BIP0340](https://github.com/akovalenko/bip0340). A complete list of dependencies can be found in the [system definition file](./nostr-bot.asd).

# Installation and usage

BIP0340 (Used for event signing) is not directly available in quicklisp repositories so you will need to manually add it so asdf can locate it:

```shell
git clone https://github.com/akovalenko/bip0340.git ~/quicklisp/local-projects/
```

Next clone this repo to the same location:

```shell
git clone https://github.com/Shinoa-Fores/nostr-bot.git ~/quicklisp/local-projects
```

Copy the [nostr.conf](./nostr.conf) file to `~/.config/n/nostr.conf` and populate it with your hex-encoded public key, and the bot's corresponding keypair. You can change the defined relay for the bot by editing [this parameter](https://github.com/Shinoa-Fores/nostr-bot/blob/master/bot.lisp#L19).

Start your REPL and load the project via quicklisp:

```lisp
(ql:quickload :nostr-bot)
```

Switch to the loaded package:

```lisp
(in-package :nostr-bot)
```

Start the bot:

```lisp
(start-bot)
```

Simply `ctrl + c` to quit. (Not portable, only tested in sbcl)

Users can define new commands by adding them to [commands.lisp](./commands.lisp). A basic `eval` command to evaluate lisp expressions (bot admin only) and `gm` (which replies back with gm) are included to get you started.

------
Contact me on [nostr](https://nostr.band/npub1f0restzwusrck2k62dq2ueelrrfmdfnyk8uhart8n8nqwn94cwwsppm0sa)
npub1f0restzwusrck2k62dq2ueelrrfmdfnyk8uhart8n8nqwn94cwwsppm0sa
