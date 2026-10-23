# Commit boundary

Never commit site identity to GitHub.

Do not commit a domain name, a LAN address, a gateway, a LAN prefix, a real name, or a personal account name that is not the public GitHub login.

That includes docs, comments, examples, and history.

`settings.nix` is the only eval-time copy. Do not repeat its values in another file.

Do not force-push a history rewrite unless the user asks for that rewrite in the current conversation.
