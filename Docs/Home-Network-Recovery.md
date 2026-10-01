# Home Network Recovery Guide

> **Status:** outline only. Fill this in after the current Clanker/network audit with live-verified steps and screenshots/labels where useful.
>
> Audience: somebody who should be able to get the house back onto ordinary Internet/DNS without needing to understand Kyle's lab.

## Goal

Provide a plain-language way to understand the home network, recover basic Internet/DNS, and temporarily remove Kyle-specific infrastructure when troubleshooting.

## Normal network overview

TODO: document, in plain language:

- Verizon router / Internet connection
- Pi-hole / local DNS role
- Molasses and any other local infrastructure involved in DNS
- Clanker / WireGuard dependencies that can affect home DNS
- which devices are optional lab infrastructure versus required for ordinary Internet access
- where DHCP is provided
- what DNS addresses clients normally receive

## If DNS stops working

TODO: verified decision tree with the fastest low-risk checks first.

Include:

- how to tell Internet failure from DNS failure
- how to check whether Pi-hole is reachable
- how to check the configured Pi-hole upstream resolver
- how to switch Pi-hole to a known third-party resolver temporarily
- how to switch Pi-hole back to the normal local resolver
- how to bypass Pi-hole entirely if necessary

## Pi-hole resolver changes

TODO: live-verify exact UI paths and current configuration before documenting.

Must include:

- normal/local resolver configuration
- temporary third-party DNS configuration
- how to reverse the temporary change
- what settings should not be changed

## Restore Verizon/default DNS

TODO: live-verify the exact Verizon router UI and current DHCP/DNS configuration.

Must include:

- how to make the router hand out Verizon/default DNS again
- how to remove/bypass custom Pi-hole DNS settings
- how to verify a client received working DNS afterward
- how to restore Kyle's normal configuration later

## Firewall recovery / reset

TODO: document only after current firewall audit.

Must include:

- what firewall(s) are involved
- safe way to return to a simple/default ruleset
- which custom forwarding/routing rules are Kyle-specific
- what must be preserved for ordinary Internet access
- how to verify Internet and DNS after a reset
- how to restore the custom rules from version-controlled documentation/backups

## "Pre-Kyle" / simple network mode

TODO: define and test a reversible procedure that leaves the house with basic Verizon Internet and ordinary DNS while disabling or bypassing hobby/lab dependencies.

The procedure should:

1. preserve ordinary Internet access;
2. stop depending on Clanker, WireGuard, DN42, Yggdrasil, or experimental services;
3. bypass local DNS infrastructure if needed;
4. avoid deleting configuration where a reversible disable/bypass is possible;
5. include exact steps to return to the normal setup.

## Rebooting equipment

TODO: list safe reboot order and approximate recovery times for:

- Verizon router
- Pi-hole host / Molasses
- switches or access points, if applicable
- other home infrastructure that actually matters to ordinary Internet access

## What not to touch

TODO: short list of settings/files/services that are not needed for basic recovery and should be left alone.

## Kyle's recovery notes

TODO: technical appendix pointing to UsefulScripts documentation, backups, host inventories, and version-controlled configuration.

---

This document should stay intentionally simpler than the infrastructure dossiers. Its purpose is to restore ordinary household connectivity, not administer the lab.
