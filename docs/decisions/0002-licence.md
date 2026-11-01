# 0002: Licence for the public repository

Date: 2026-11-01. Status: accepted.

## Context

The repository goes public so CI runs on GitHub's free standard runners (macOS minutes count ten times against a private repository's allowance). Until now the code was marked MPL-2.0, but it had never been published, and GRAPHIQ Studio LLC owns all of it. Folio earns its money from an optional Premium purchase in the App Store app. The realistic risk is someone shipping the code as a competing app.

## Options

| Licence | What others may do | Why not / why |
|---|---|---|
| MPL-2.0 | Anything, including a competing paid app, as long as changed files stay open and the name and icon aren't used | No protection for the paid app |
| PolyForm Shield or Noncommercial | Use except competing or commercial use; never opens up | Stricter than needed |
| All rights reserved | Read only | Unfriendly; contributors can't legally do much |
| **FSL-1.1-ALv2** | Read, use, modify, self-host and redistribute for anything except a Competing Use; each version becomes Apache 2.0 after two years | **Chosen** |

## Decision

- Folio is licensed under the Functional Source License, Version 1.1, ALv2 Future License, using the official text from `getsentry/fsl.software` (`FSL-1.1-ALv2.template.md`, commit dba73c4).
- The public repository starts with a fresh history, so no earlier commit is published under the MPL. The full earlier history is kept privately on Forgejo (`andrej/folio`, branch `archive/pre-public`).
- Outside code contributions wait until there is a contributor agreement.
- Third-party components keep their own licences (FluidAudio Apache-2.0, Kokoro and Paradee Apache-2.0, Supertonic OpenRAIL-M, SQLite public domain; see NOTICE). None conflicts with FSL.

## Consequences

- FSL is "Fair Source", not OSI-approved open source; the README says so plainly.
- Each published version becomes Apache 2.0 two years after its release.
