
!!! quote "Connect your developers. Then connect your applications."

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

```
S: I don't know the addresses of the workers, so you should connect to me.

R: I'll send a HelloRequest, because the worker can process only specific PDL types,
   the PDL header will contain either PS or PDF.

S: Do I need to send you a HelloResponse?

R: No, just start sending me messages with PDL data.

S: As signals?

R: No, as multi-requests — each with a message ID equal to the job ID.

S: You forgot the Job Ticket.

R: Right. The first request should have a JobTicket header (JDF or PPD) and the
   ticket data in the body. The following requests will have the PDL header
   (PDF or PS) with the related content.

S: But JDF is usually used only for PDF...

R: Yes, but let's keep it flexible.

S: Can you process several jobs simultaneously?

R: It depends on licensing. Anyway, if I can, I'll send another HelloRequest —
   working one job per channel looks cleaner.

S: I need a progress indicator.

R: No problem. I'll send signals with the same message ID — the Progress header
   will show the range [N:M] for page numbers.

S: On job finish, send me a Response with the same message ID and processing status.
   Also include the Progress header.

R: Why should I send an obsolete message? Are you expecting a graceful close?

S: Of course.

R: Then I'll send a ByeRequest with the same information, and you'll send me a
   ByeResponse. After that connection will be autimatically aborted.

S: That's enough for today. Send me a short text file with this protocol —
   I'll save it in Git.

R: Deal. How about a cup of coffee?
```

I hope you got the point without long smart descriptions or advertising.

