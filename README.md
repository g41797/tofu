![](_logo/Ziggy_And_Zero_Are_Cooking_Tofu.png)
# **_Tofu - Sync your devs, Async your apps_**!

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Linux](https://github.com/g41797/yaaamp/actions/workflows/linux.yml/badge.svg)](https://github.com/g41797/yaaamp/actions/workflows/linux.yml)
<!-- [![MacOS](https://github.com/g41797/yaaamp/actions/workflows/mac.yml/badge.svg)](https://github.com/g41797/yaaamp/actions/workflows/mac.yml) -->

---

**tofu** is a _protocol_ and an _asynchronous_ **Zig messaging library** used to:

- Build **custom** communication flows.
- Create **non-blocking** systems.
- Enable **peer-to-peer** messaging between applications.

**tofu** is a completely new project. It is not a port of old code, and it does not use any C libraries.
It is built **100% in native Zig**. The core functionality uses only the standard library.

---

## Why tofu?

As a food, **tofu** is very simple and has almost no flavor on its own.
By using tofu **cubes**, you can:

- Eat it **plain** for a simple snack.
- Add a little **spice** to make it better.
- Create a **culinary masterpiece**.

As a **protocol**, tofu uses **messages** like cubes. By "cooking" these messages together, you can grow your project:

- Start with **minimal setups**.
- Build **complex flows**.
- Create full **distributed applications**.

> [!IMPORTANT]
> **tofu** is as good as you are a cook.

---

## A Bit of History

**tofu** did not come from nowhere.

The journey began in 2008 when I first built a similar system. I maintained and ran that system
for many years in high-stakes environments. It powered everything from basic IPC to complex data transfers in a custom distributed file system.

I left that project a few years ago, but I haven't heard any complaints yet — the systems are still running strong.

Corporate lawyers can stay calm: I didn't take any code. I only took the "**smell**."
(See the [precedent case about paying for a smell](http://fable1001.blogspot.com/2009/11/nasreddin-hodja-smell-of-soup-and-sound.html)).

By "**smell**," I mean the core philosophy:

- **The Message is the API**: The data itself defines the connection.
- **Gradual Evolution**: Start with something simple and grow it into a powerful system over time.
- **The Mantra**: "Connect your developers. Then connect your applications."


## "Connect your developers. Then connect your applications."

This **tofu** mantra is a paraphrase of [Conway's Law](https://en.wikipedia.org/wiki/Conway%27s_law). 

**tofu** "expects" that development starts with a conversation (_connection_) similar to the one shown below.

**Context:**

- Two developers are discussing the message flow for a new Print Server.
- The first one is the _Spool Server_ developer (**S**).
- The second one develops the _RIP Worker Process_ (**R**).
- Don’t worry — RIP means *Raster Image Processing*, not what you might think.
- Some terms may be unknown — that’s fine. These two know exactly what they mean.

This dialog is shown without the usual jokes or side comments common in real programmer discussions — just the technical part.

---

>
> **S:**  
> I don’t know the addresses of the workers, so you should connect to me.
>
> **R:**  
> I’ll send a **HelloRequest**, because the worker can process only specific _PDL_ types, the **PDL** header will contain either **PS** or **PDF**.
>
> **S:**  
> Do I need to send you a **HelloResponse**?
>
> **R:**  
> No, just start sending me messages with PDL data.
>
> **S:**  
> As _signals_?
>
> **R:**  
> No, as _multi-requests_ — each with a **message ID** equal to the **job ID**.
>
> **S:**  
> You forgot the _Job Ticket_.
>
> **R:**  
> Right. The first request should have a **JobTicket** header (**JDF** or **PPD**) and the ticket data in the body.  
> The following requests will have the **PDL** header (PDF or PS) with the related content.
>
> **S:**  
> But JDF is usually used only for PDF...
>
> **R:**  
> Yes, but let’s keep it flexible.
>
> **S:**  
> Can you process several jobs simultaneously?
>
> **R:**  
> It depends on licensing. Anyway, if I can, I’ll send another **HelloRequest** — working one job per _channel_ looks cleaner.
>
> **S:**  
> I need a progress indicator.
>
> **R:**  
> No problem. I’ll send _signals_ with the same **message ID** — the **Progress** header will show the range [N:M] for page numbers.
>
> **S:**  
> On job finish, send me a **Response** with the same **message ID** and processing _status_.  
> Also include the **Progress** header.
>
> **R:**  
> Why should I send an obsolete message? Are you expecting a graceful close?
>
> **S:**  
> Of course.
>
> **R:**  
> Then I’ll send a **ByeRequest** with the same information, and you’ll send me a **ByeResponse**.  
> After that, I’ll abort the connection immediately.
>
> **S:**  
> That’s enough for today. Send me a short text file with this protocol — I’ll save it in Git.
>
> **R:**  
> Deal. How about a cup of coffee?
> 



I hope you got the point without long smart descriptions or advertising.


## Features
 
- **Message-Based**: Uses discrete messages for communication.
- **Asynchronous**: Enables non-blocking message exchanges.
- **Duplex**: Supports two-way communication.
- **Peer-to-Peer**: Allows equal roles after connection establishment.
- **Stream oriented transport** - TCP/IP and **U**nix **D**omain **S**ockets
- **Multithread-friendly** - All APIs are safe for concurrent access.
- **Memory management for messages** - internal message pool
- **Backpressure management** - allows to control receive of messages
- **Customizable application flows** - allows to build various application flows not restricted to request/response or pub/sub
- **Simplest API** - you don't have to bother with or know the "guts" of socket interfaces


Documentation and examples are available on the [Tofu documentation site](https://g41797.github.io/tofu/) (**_work in progress_**).

---

## AI Usage

Almost all of this project (99.99%) is "handmade."

AI was used only for these specific tasks:

* **Image Generation**
  * Generated the project [Logo](_logo/Ziggy_And_Zero_Are_Cooking_Tofu.png).
* **Code Snippets**
  * Implemented [Big-Endian (BE) to Little-Endian (LE) serialization](/src/message.zig#L86) and vice versa.
  * Implemented [data copying to message bodies](/src/message.zig#L722) and vice versa.
* **Code Refactoring**
  * **Explicit Pointer Dereferencing**: Replaced implicit "Automatic pointer dereference" with explicit `ptr.*` syntax..
  * **Explicit Type Declaration**: Replaced "Type Inference" with explicit type declarations for all variables.
  * Migration code from 0.14.1 to 0.15.2

> [!TIP]
> Configuration files and guidelines related to refactoring are located in the [.claude/rules](.claude/rules) directory.


## Credits
- [Karl Seguin](https://github.com/karlseguin) — for introducing me to [Zig networking](https://www.openmymind.net/TCP-Server-In-Zig-Part-1-Single-Threaded/)
- [tardy](https://github.com/tardy-org/tardy) — I peeked into 2 files of the project (the author will guess which ones)
- [temp.zig](https://github.com/abhinav/temp.zig) — helped me (and will help you) work with temporary files
- [Gemini AI image generator](https://gemini.google.com/app) — the only one out of six I managed to convince to seat Ziggy and Zero at the same table
- Zig Community Forums (in order of my registration) - for your help and patience with my posts
  - [Zig on Reddit](https://www.reddit.com/r/Zig/)
  - [Zig on Discord](https://discord.com/invite/zig)
  - [Zig on Discourse](https://ziggit.dev/)

---

## Last but not least
⭐️ Like, share, and don’t forget to [subscribe to the channel](https://github.com/g41797/tofu) !



