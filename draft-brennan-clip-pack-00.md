---
title: "The Clipboard Packet Transfer Protocol (CLIP-PACK/1)"
abbrev: CLIP-PACK
docname: draft-brennan-clip-pack-00
category: exp
date: 2026

ipr: trust200902
area: Transport
workgroup: Network Working Group

author:
  -
    ins: P. Brennan
    name: Patrick Brennan
    organization: Raw Mercury Limited

--------------------------------------------------------------------------------

# Abstract

This document describes CLIP-PACK/1, a protocol for the reliable transfer of
arbitrary file hierarchies between computing systems whose only viable shared
transport medium is the operating system clipboard. CLIP-PACK/1 provides
framing, integrity verification, chunked delivery with receiver-driven flow
control, and opportunistic retransmission over a transport characterised by a
single mutable slot of indeterminate capacity, no out-of-band signalling, and
an expectation that the medium may be read, written, or obliterated at any
moment by a human, an operating system component, or a password manager.

The protocol is designed for, and has been field-tested in, environments in
which a remote desktop session is the only permitted bridge between two hosts
and in which the session's clipboard channel is the sole remaining avenue for
non-interactive data exchange. It makes no claim of elegance.

# Status of This Memo

This Internet-Draft is submitted in full conformance with the provisions of
BCP 78 and BCP 79.

Internet-Drafts are working documents of the Internet Engineering Task Force
(IETF). Note that other groups may also distribute working documents as
Internet-Drafts. The list of current Internet-Drafts is at
<https://datatracker.ietf.org/drafts/current/>.

Internet-Drafts are draft documents valid for a maximum of six months and may
be updated, replaced, or obsoleted by other documents at any time. It is
inappropriate to use Internet-Drafts as reference material or to cite them
other than as "work in progress."

# Copyright Notice

Copyright (c) 2026 IETF Trust and the persons identified as the document
authors. All rights reserved.

--------------------------------------------------------------------------------

# Table of Contents

1. Introduction
2. Terminology
3. Protocol Overview
4. Message Format
   1. The DATA Message
   2. The ACK Message
   3. Lexical Conventions
5. Transfer Lifecycle
   1. Preparation
   2. Single-Chunk Transfers
   3. Multi-Chunk Transfers
   4. Retransmission
   5. Completion
6. State Machines
   1. Sender State Machine
   2. Receiver State Machine
7. Transport Considerations
   1. The Clipboard as a Network
   2. Congestion Control
   3. Head-of-Line Blocking
   4. Maximum Transmission Unit Discovery
8. Security Considerations
9. Operational Considerations
10. IANA Considerations
11. Comparison With Existing Work
12. References
    1. Normative References
    2. Informative References

--------------------------------------------------------------------------------

# 1. Introduction

The design of modern network protocols has historically assumed the
availability of a bidirectional byte stream, or at minimum an unreliable
datagram service, between communicating endpoints. A substantial body of work
[RFC0793] [RFC0768] [RFC9000] exists to address the resulting engineering
problems.

Less attention has been paid to the case in which neither of these
abstractions is available, and the only shared medium between two hosts is a
single mutable memory region, conventionally referred to as "the clipboard",
into which either endpoint may write at any time, from which either endpoint
may read at any time, and whose contents may be silently truncated,
reformatted, or replaced by processes wholly outside the control of either
endpoint.

This document specifies a protocol for reliable file transfer across such a
medium. The protocol is motivated by, and primarily deployed within, the
following operational context:

- A user's local workstation is connected to a remote virtualised session
  (commonly via Citrix, VMware Horizon, or similar) for security or
  compliance reasons.
- Direct network access between the local workstation and the remote session
  is prohibited or infeasible.
- File upload and download interfaces within the remote session are disabled,
  rate-limited, or subject to review processes measured in business days.
- The clipboard virtual channel, while subject to its own restrictions, is
  permitted, because without it the session is unusable.

In this environment, the clipboard becomes the transport of last resort. This
document describes how to use it as one without losing one's data, one's
sanity, or one's afternoon.

The protocol is deliberately simple. It does not attempt to be a general
transport: it is a batch-oriented, unidirectional file-hierarchy delivery
mechanism with acknowledgements. It does not multiplex. It does not encrypt
(the user is presumed to trust both endpoints; if they did not, they would
not be typing into both of them). It does not compress beyond what is
necessary to fit through the medium. It does, however, verify.

# 2. Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in
this document are to be interpreted as described in BCP 14 [RFC2119]
[RFC8174] when, and only when, they appear in all capitals, as shown here.

The following terms are used throughout this document:

Clipboard
: A single-slot mutable storage region, shared between two or more processes,
  supporting read and overwrite operations but not append. The clipboard is
  assumed to hold a single value of indeterminate but finite maximum length.
  Its contents are volatile; any cooperating or uncooperating process may
  overwrite it at any time.

Sender
: The endpoint executing the packing role (see Section 3). The sender
  originates DATA messages and consumes ACK messages.

Receiver
: The endpoint executing the unpacking role. The receiver consumes DATA
  messages and originates ACK messages.

Chunk
: A discrete unit of transfer. A complete transfer consists of one or more
  chunks. Chunks are numbered from 1.

Transfer
: The complete delivery of a single file hierarchy from sender to receiver,
  consisting of exactly `total` chunks where `total >= 1`.

Transfer ID
: An identifier distinguishing one transfer from another on the same
  clipboard, used by the receiver to recognise duplicate or stale content and
  by the sender to route ACKs.

Payload
: The base64-encoded, xz-compressed tar archive produced from the sender's
  source directory.

# 3. Protocol Overview

A CLIP-PACK/1 transfer proceeds as follows:

1. The sender recursively archives a source directory into a POSIX tar
   archive [USTAR], compresses it with xz at maximum compression [RFC6713],
   and encodes the result as base64 [RFC4648] with no line breaks. The
   resulting octet sequence is the payload.
2. The sender computes the SHA-256 [FIPS-180-4] digest of the uncompressed
   tar archive. This digest is the transfer's authoritative integrity
   witness.
3. If the payload is smaller than a configured chunk size threshold, it is
   wrapped in a single DATA message and written to the clipboard.
4. If the payload exceeds the threshold, it is partitioned into N contiguous
   chunks, each wrapped in a DATA message bearing a chunk index and the
   SHA-256 of its own base64 slice. Chunks are transmitted sequentially, with
   the sender waiting for an ACK message on the clipboard before proceeding
   to the next.
5. The receiver reads the clipboard, validates the DATA message, writes the
   chunk to local storage, and — for multi-chunk transfers — writes an ACK
   message to the clipboard.
6. Upon receipt of the final chunk, the receiver reassembles the payload,
   decodes and decompresses it, and verifies the resulting tar archive
   against the SHA-256 supplied in the header.

The protocol is half-duplex. Only one endpoint writes to the clipboard at a
time, and each write completely overwrites the previous contents. This is
unavoidable: the medium has no concurrency model.

# 4. Message Format

A CLIP-PACK/1 message consists of a header, a separator line, and an
OPTIONAL body. All three components are text. The message is encoded as
UTF-8, though in practice all header fields are restricted to US-ASCII.

Two message types are defined: DATA and ACK.

## 4.1. The DATA Message

A DATA message has the following structure:

```
CLIP-PACK-V1\n
transfer-id=<transfer-id>\n
chunk=<chunk-index>\n
total=<total-chunks>\n
chunk-sha256=<hex-digest>\n
tar-sha256=<hex-digest>\n
---\n
<base64-payload>
```

Field definitions:

`CLIP-PACK-V1`
: The protocol magic. The first line of a DATA message MUST be exactly this
  string. Implementations MUST reject any clipboard contents whose first
  line does not match.

`transfer-id`
: An identifier for this transfer. Implementations SHOULD generate this as 8
  lowercase hexadecimal characters derived from a cryptographic random
  source. Implementations MAY permit user-supplied values, in which case the
  value MUST consist of printable US-ASCII characters excluding whitespace,
  `=`, and any newline.

`chunk`
: The 1-indexed position of this chunk within the transfer. MUST be a
  positive decimal integer. MUST be less than or equal to `total`.

`total`
: The total number of chunks comprising this transfer. MUST be a positive
  decimal integer. MUST NOT change across chunks of the same transfer.

`chunk-sha256`
: The SHA-256 digest, expressed as 64 lowercase hexadecimal characters, of
  the chunk's base64 payload octet sequence exactly as it appears after the
  separator.

`tar-sha256`
: The SHA-256 digest, expressed as 64 lowercase hexadecimal characters, of
  the uncompressed tar archive. This value is identical in every chunk of a
  transfer and is the authoritative integrity check for the transfer as a
  whole.

`---`
: A literal three-hyphen line serving as the header/body separator.
  Implementations MUST locate the first occurrence of this line and treat
  everything following it as the body.

`<base64-payload>`
: The body of the DATA message. Contains a contiguous slice of the full
  base64-encoded, xz-compressed tar archive. For single-chunk transfers,
  contains the entire encoded payload.

Header fields other than `CLIP-PACK-V1` MAY appear in any order. Future
versions of this protocol MAY define additional header fields; implementations
of CLIP-PACK/1 MUST ignore unrecognised fields.

## 4.2. The ACK Message

An ACK message has the following structure:

```
CLIP-PACK-ACK\n
transfer-id=<transfer-id>\n
chunk=<chunk-index>\n
---\n
```

Field definitions follow Section 4.1. The body of an ACK message is empty;
the trailing separator is REQUIRED for parsing symmetry.

An ACK acknowledges receipt and successful verification of a single chunk.
ACKs for single-chunk transfers are OPTIONAL and typically omitted.

## 4.3. Lexical Conventions

All header lines terminate with a single LF (`\n`, 0x0A). Implementations
SHOULD accept CRLF (`\r\n`) terminators, as certain platforms — notably those
reading the clipboard via PowerShell under Windows Subsystem for Linux —
introduce CR octets that cannot be reliably suppressed at the transport
layer. Implementations MUST strip trailing CR octets from header lines before
parsing.

Base64 payload data MAY contain embedded whitespace introduced by clipboard
intermediaries. Receivers MUST strip all whitespace from the body before
decoding.

# 5. Transfer Lifecycle

## 5.1. Preparation

Before initiating a transfer, the sender:

1. Creates a tar archive of the source hierarchy. Platform-specific extended
   attributes and metadata files SHOULD be excluded to improve portability
   and avoid surprise.
2. Computes the SHA-256 of the uncompressed tar byte stream. This
   computation is performed inline with compression via a teed pipeline to
   avoid buffering the archive on disk.
3. Compresses the tar stream with xz at maximum compression.
4. Base64-encodes the compressed stream, emitting a single line with no
   embedded whitespace.

The resulting payload is ready for transmission.

## 5.2. Single-Chunk Transfers

If the payload fits within the configured chunk threshold, the sender
constructs a single DATA message with `chunk=1` and `total=1` and writes it
to the clipboard. The transfer is then complete from the sender's
perspective. The sender SHOULD display the tar SHA-256 so that the user can
compare it against the value reported by the receiver.

## 5.3. Multi-Chunk Transfers

If the payload exceeds the chunk threshold, the sender partitions it into N
chunks of no more than the threshold size in octets. Chunk boundaries fall
at arbitrary offsets within the base64 stream; the receiver reassembles by
simple concatenation.

For each chunk in order:

1. The sender constructs a DATA message and writes it to the clipboard.
2. The sender polls the clipboard for an ACK message matching
   `transfer-id` and `chunk` of the just-sent chunk.
3. Upon observing a matching ACK, the sender proceeds to the next chunk.

The receiver, upon observing the first DATA message (with `chunk=1`), begins
collecting chunks. For each subsequent chunk:

1. The receiver polls the clipboard at a reasonable interval (1 second is
   RECOMMENDED) for a DATA message whose `transfer-id` matches the transfer
   in progress and whose `chunk` equals the next expected index.
2. Upon observing such a message, the receiver verifies `chunk-sha256`,
   stores the chunk locally, and writes a matching ACK to the clipboard.

## 5.4. Retransmission

The clipboard is not a reliable transport. Its contents may be overwritten
at any time by processes unrelated to the transfer: a user who pastes
elsewhere, a password manager that clears the clipboard on a timer, a
keystroke emitted in error. CLIP-PACK/1 therefore defines two retransmission
triggers:

Clipboard-Loss Retransmission (sender):

After writing a DATA message, the sender periodically compares the current
clipboard contents to the last message it wrote. If the contents differ and
no matching ACK has been observed for at least 10 seconds, the sender MUST
retransmit the same chunk. This handles the common case of a user
inadvertently overwriting the clipboard between a sender write and a
receiver read.

Duplicate-ACK Retransmission (receiver):

If the receiver observes a DATA message whose `chunk` index is less than the
currently expected index, and whose payload matches a previously stored
chunk, the receiver MUST respond with an ACK for that earlier chunk. This
permits the sender to advance after a clipboard-loss retransmission of an
already-acknowledged chunk crossed paths with an in-flight ACK.

These two mechanisms together provide adequate reliability in practice. They
do not provide adequate reliability in theory.

## 5.5. Completion

A transfer is complete when:

- The receiver has stored all `total` chunks.
- The receiver has reassembled the chunks by concatenation, decoded the
  result from base64, and decompressed it.
- The receiver has computed the SHA-256 of the resulting tar archive and
  verified that it matches the `tar-sha256` value from any DATA header.

If the final verification fails, the receiver MUST abort the transfer and
MUST NOT extract the archive. The failure mode most commonly indicates that
the clipboard transport truncated one or more chunks; see Section 7.4.

# 6. State Machines

## 6.1. Sender State Machine

```
         +----------+
         |   IDLE   |
         +----------+
              |
              | prepare payload
              v
         +----------+
         | PREPARED |
         +----------+
              |
              | write chunk N to clipboard
              v
         +----------+
    +--->|   SENT   |
    |    +----------+
    |         |
    |         +--- ACK received ---+
    |         |                    |
    |         +--- clipboard lost  |
    |         |    >= 10s          |
    |         |    (retransmit)    |
    |         v                    v
    |    +----------+         +----------+
    |    | WAITING  |         | RESEND   |---+
    |    +----------+         +----------+   |
    |                              |         |
    +------------------------------+---------+
              |
              | all chunks ACKed
              v
         +----------+
         |   DONE   |
         +----------+
```

## 6.2. Receiver State Machine

```
         +----------+
         |  POLLING |<-------------------+
         +----------+                    |
              |                          |
              | DATA(chunk=1) observed   |
              v                          |
         +----------+                    |
         | VERIFY   |                    |
         +----------+                    |
              |                          |
              | checksum OK              |
              v                          |
         +----------+                    |
         |  STORE   |--------------------+
         +----------+   (write ACK,
              |         expect next)
              | all chunks stored
              v
         +----------+
         | ASSEMBLE |
         +----------+
              |
              | tar SHA-256 verified
              v
         +----------+
         | EXTRACT  |
         +----------+
```

# 7. Transport Considerations

## 7.1. The Clipboard as a Network

The clipboard differs from a conventional network in the following respects
relevant to protocol design:

- It is a single-slot store, not a queue. A write replaces, rather than
  appends to, the previous value.
- It has no addressing. Every cooperating and uncooperating process on
  either endpoint has equal access.
- It has no notification. The receiver must poll.
- Its maximum capacity is a policy decision enforced by the underlying
  desktop virtualisation layer, typically expressed as an integer number of
  kilobytes. This value is not advertised to applications and may change
  without notice.
- It exhibits silent truncation. A write of N octets may be observable by
  the receiver as a write of fewer than N octets, with no error returned to
  either endpoint.

These properties inform the remainder of this section.

## 7.2. Congestion Control

CLIP-PACK/1 does not implement congestion control in the traditional sense.
The transport lacks the observability required: there is no packet loss
indication, no round-trip time estimator, no ECN signal. Congestion, to the
extent it exists, manifests as silent truncation.

The sender's chunk size threshold is therefore functionally equivalent to a
congestion window, but it is configured statically by the user based on
operational knowledge of the deployment. A sender that observes repeated
checksum failures SHOULD be reconfigured by the user to use smaller chunks.

## 7.3. Head-of-Line Blocking

The protocol exhibits complete head-of-line blocking by design. This is not
regarded as a defect. The alternative — out-of-order delivery — would
require either multiple clipboards (the medium supports one) or a
multiplexing layer within the payload (the medium does not reward
complexity).

## 7.4. Maximum Transmission Unit Discovery

CLIP-PACK/1 does not perform path MTU discovery. The clipboard MTU is a
deployment characteristic communicated to the sender by the user through
the `--size` parameter. Operators SHOULD determine the MTU empirically, by
attempting a transfer at a conservative chunk size and increasing until
checksum failures are observed, then decreasing below that threshold.

Typical observed MTUs in production Citrix deployments range from 512 KB
(default configuration) to tens of megabytes (reconfigured by administrators
who have grown weary of support tickets).

# 8. Security Considerations

CLIP-PACK/1 provides integrity verification via SHA-256 but does not provide
confidentiality, authentication, or protection against active attackers with
clipboard access.

The threat model assumes:

- Both endpoints are controlled by the same user.
- Both endpoints are trusted by that user.
- Any adversary with write access to either clipboard already has
  substantially greater capabilities than this protocol could
  meaningfully restrict.

Implementations SHOULD note that the clipboard is a shared resource. On the
sending host, any local process may read the clipboard and thereby observe
the full payload. On the receiving host, any local process may write to the
clipboard and thereby inject DATA messages. A malicious DATA message will
fail checksum verification at the receiver, but a malicious message crafted
to match a valid SHA-256 would permit arbitrary content extraction. The
computational cost of producing such a collision is presently believed to be
prohibitive; implementations SHOULD revisit this assumption if and when it
ceases to be true.

Users transferring sensitive data SHOULD consider encrypting the source
directory before invoking the sender, via any mechanism producing a
ciphertext artefact ingestible as ordinary files. The protocol is agnostic
to payload content.

The `--id` parameter provides weak multi-tenancy: it prevents the receiver
from accidentally extracting a transfer initiated by another instance of the
sender. It does not provide any security property. An attacker observing the
clipboard can trivially read the transfer ID from any DATA header and craft
matching messages.

The protocol's `CLIP-PACK-ACK` mechanism creates a covert back-channel from
receiver to sender. This is unavoidable given the transport. Operators in
environments with strict unidirectionality requirements (where the clipboard
is permitted to flow inward but not outward, or vice versa) SHOULD NOT use
multi-chunk transfers, as the ACK traffic violates the assumed flow
direction.

# 9. Operational Considerations

The protocol interacts poorly with the following:

Password managers configured to clear the clipboard after N seconds
: These will corrupt in-flight transfers. Users SHOULD disable the relevant
  feature, or SHOULD configure it to skip CLIP-PACK traffic. In practice,
  users will forget to do this exactly once.

Clipboard managers that deduplicate entries
: A DATA message written twice in succession (as may occur during
  retransmission) may be recorded only once in the manager's history. This
  is usually benign but may confuse debugging.

Automatic clipboard synchronisation between devices
: Implementations that synchronise a user's clipboard between a
  workstation, a phone, and a tablet introduce three additional observers
  and two additional potential sources of overwrites. Disabling such
  synchronisation for the duration of a transfer is RECOMMENDED.

Colleagues standing behind the operator
: Will, without fail, ask what is happening. A brief explanation of the
  protocol may or may not satisfy them. This is out of scope for this
  document.

# 10. IANA Considerations

This document makes no requests of IANA.

The protocol does not use, consume, or interact with any IANA-maintained
registry. It operates entirely within the operating system clipboard, which
IANA has historically and sensibly declined to register.

# 11. Comparison With Existing Work

CLIP-PACK/1 is not the first protocol designed for unconventional transports.
The authors note the following prior art:

- IP over Avian Carriers [RFC1149] addresses the case of hosts connected by
  carrier pigeons. CLIP-PACK/1 differs in that the transport does not flap
  its wings.
- The HTCPCP protocol [RFC2324] addresses the case of hosts connected to
  coffee pots. CLIP-PACK/1 differs in that it does not return 418.
- The various iterations of kermit [KERMIT] addressed the case of hosts
  connected by serial lines of dubious quality. CLIP-PACK/1 shares
  kermit's spiritual commitment to getting data through whatever channel
  happens to exist; it lacks kermit's willingness to run for hours to do so.

To the best of the author's knowledge, CLIP-PACK/1 is the first formally
specified protocol for file transfer over a single-slot shared mutable
memory region accessed via cut-and-paste.

It is unlikely to be the last. The circumstances that made this protocol
necessary are not going away.

# 12. References

## 12.1. Normative References

[RFC2119]
: Bradner, S., "Key words for use in RFCs to Indicate Requirement Levels",
  BCP 14, RFC 2119, March 1997.

[RFC8174]
: Leiba, B., "Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words",
  BCP 14, RFC 8174, May 2017.

[RFC4648]
: Josefsson, S., "The Base16, Base32, and Base64 Data Encodings", RFC 4648,
  October 2006.

[FIPS-180-4]
: National Institute of Standards and Technology, "Secure Hash Standard
  (SHS)", FIPS PUB 180-4, August 2015.

[USTAR]
: IEEE, "IEEE Standard for Information Technology — Portable Operating
  System Interface (POSIX), Base Specifications", IEEE Std 1003.1-2017.

## 12.2. Informative References

[RFC0768]
: Postel, J., "User Datagram Protocol", STD 6, RFC 768, August 1980.

[RFC0793]
: Postel, J., "Transmission Control Protocol", STD 7, RFC 793, September
  1981.

[RFC1149]
: Waitzman, D., "A Standard for the Transmission of IP Datagrams on Avian
  Carriers", RFC 1149, April 1990.

[RFC2324]
: Masinter, L., "Hyper Text Coffee Pot Control Protocol (HTCPCP/1.0)",
  RFC 2324, April 1998.

[RFC6713]
: Levine, J., "The 'application/zlib' and 'application/gzip' Media Types",
  RFC 6713, August 2012.

[RFC9000]
: Iyengar, J. and M. Thomson, "QUIC: A UDP-Based Multiplexed and Secure
  Transport", RFC 9000, May 2021.

[KERMIT]
: da Cruz, F., "Kermit, A File Transfer Protocol", Digital Press, 1987.

--------------------------------------------------------------------------------

# Appendix A. Example Transfer

The following trace illustrates a two-chunk transfer with transfer ID
`a1b2c3d4`.

Sender writes to clipboard:

```
CLIP-PACK-V1
transfer-id=a1b2c3d4
chunk=1
total=2
chunk-sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
tar-sha256=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
---
/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4C8AdZBdAC4AAAAA...
```

Receiver observes, verifies chunk SHA, stores, and writes:

```
CLIP-PACK-ACK
transfer-id=a1b2c3d4
chunk=1
---
```

Sender observes ACK, writes chunk 2:

```
CLIP-PACK-V1
transfer-id=a1b2c3d4
chunk=2
total=2
chunk-sha256=1b4f0e9851971998e732078544c96b36c3d01cedf7caa332359d6f1d83567014
tar-sha256=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
---
...OQBCcyVhuEhm/W+rTF3yNdgBnI5eAJA2CkXjaAmhAkYA
```

Receiver observes, verifies chunk SHA, stores, writes:

```
CLIP-PACK-ACK
transfer-id=a1b2c3d4
chunk=2
---
```

Receiver concatenates chunks, base64-decodes, xz-decompresses, verifies the
resulting tar SHA against `9f86d081...0a08`, and extracts the archive.

# Appendix B. Acknowledgements

The author thanks the designers of modern enterprise desktop virtualisation
products, without whose operational constraints this protocol would have no
reason to exist and no users.

# Author's Address

Patrick Brennan
Raw Mercury Limited
New Zealand

Email: (redacted)
