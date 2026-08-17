# Marlboro Media — SMS Notifications

**Program name:** Marlboro Media
**Message type:** Account notification (media request status)
**Operator:** Ben Calegari
**Contact:** lap.rapper_3o@icloud.com
**Number:** +1 (812) 616-4925

---

## What this is

Marlboro Media is a private, self-hosted media server run for one household and a small
number of friends. Members can text the number above the name of a movie or TV series to
add it to the library, and receive one message back when it is available to watch.

This is not a commercial service. Nothing is sold, and no marketing, promotional, or
advertising messages are ever sent.

## Who receives messages

Only people who asked to be included and gave their phone number directly to the operator.

Numbers are added by hand, one at a time, to a private allowlist on the operator's own
server. A number that is not on that allowlist receives no messages of any kind — the
system will not reply to it, and will not send to it.

There is **no** web signup form, and numbers are never purchased, rented, imported,
scraped, or obtained from any third party.

## How members opt in

Two ways, both explicit:

**1. Verbal, in person.** Members are asked directly and told what they will receive
before their number is added. The wording used:

> "I run a media server at home. If you text this number the name of a movie or show,
> it'll get added and text you back when it's ready to watch. It only ever texts you
> about stuff you asked for. Want me to add your number? You can reply STOP any time
> and it'll stop."

**2. Consumer-initiated, by text.** Every conversation begins with the member texting the
number first. The system never starts a conversation. Each outbound message is either a
direct reply to a message the member just sent, or a status update about the specific
title that member personally requested.

## What members receive

Every message is prefixed with the program name so the sender is always identifiable. The
opt-out notice appears on the first message of a conversation.

A member texts a title, and gets back a numbered list to choose from:

```
Marlboro Media: 1. Dune: Part Two (2024) [movie]
2. Dune (2021) [movie]
Reply 1-2 to request.
Reply STOP to opt out.
```

They reply with a number, and get a confirmation:

```
Marlboro Media: Requested Dune: Part Two. You'll get a text when it's on Jellyfin.
```

When that title is ready to watch, they get one notification:

```
Marlboro Media: Dune: Part Two is ready on Jellyfin.
```

If the request cannot be filled, they are told rather than left waiting:

```
Marlboro Media: Dune: Part Two failed to download. Ben will have to look.
```

## Message frequency

Message frequency varies. Messages are only ever sent in response to a member's own
request, so the volume is entirely determined by the member. In practice this is a few
messages per week across all members.

## Opting out

**Reply STOP to any message to stop receiving them.** Opt-out is processed automatically
at the carrier level and takes effect immediately. **Reply HELP for help.** Members can
also simply ask the operator to remove their number, which deletes it from the allowlist.

## Cost

Message and data rates may apply.

## Privacy

Phone numbers are used for one purpose only: delivering the notifications described above.

They are not sold, rented, shared, or disclosed to any third party. They are not used for
marketing. They are stored on the operator's own hardware, not with any external service,
and are deleted on request.
