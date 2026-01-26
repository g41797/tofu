# Callback Enabled

I don't like callbacks.

In fact, I've had some bad experiences with them.

I once caught a programmer running an entire RIP process *inside* a callback on message receipt.

I also remember realizing that, in another callback, a developer had loaded a JVM just to run Java code—inside a C++ worker process.

And let's not forget [Callback Hell](https://en.wiktionary.org/wiki/callback_hell).

In the early 2000s (the dot-com bubble era), I visited the industry's largest exhibition. In the hangar of the biggest vendor, all the walls were covered in posters with the slogan: **"Internet enabled."**

I asked every representative I could find: "What does that actually mean?"

After many attempts, one frustrated man finally **replied loudly**:
> "All our computers have a web server. Take it and do what you wish!"

In that same spirit, tofu is "**_Callback enabled_**."

> Once you've received the message, do what you wish—including calling your own callbacks.
