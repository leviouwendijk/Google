# Google

Swift package for Google APIs.

- `Google`: credentials (Desktop OAuth client, `authorized_user`), the browser
  authorization with PKCE, refresh and revocation, a token cache, and the
  authorized transport (Google error envelope, refresh once on 401, backoff
  for reads only).
- `GoogleContacts`: the People API. Contacts, contact groups, and an upsert
  keyed by an external id. What it writes shows up in Gmail and in every app
  that syncs the account, including Apple Contacts.
- `google`: the command line, a thin layer over the same operations.

Product targets depend on `Google`, never on each other.

## Setup

1. In the Cloud console, create an OAuth client of type **Desktop app** and
   enable the APIs you need (People API for contacts). Put the consent screen
   in production: in testing, refresh tokens expire after 7 days.
2. `google client import client_secret_….json --profile <name>`
3. `google authorize --profile <name> --scopes contacts` (once, in the browser)
4. `google status --profile <name>`

Credentials live in the Keychain (service `google`, items `<profile>.client`
and `<profile>.user`). On a machine without one, pass `--credentials` with an
`authorized_user` JSON file, or build a `Google.AuthorizedUser` from any
Milieu provider.

## Tests

- `sbm test`: offline (`t_google`); fixtures only, no network.
- `GOOGLE_LIVE=1 GOOGLE_LIVE_PROFILE=<name> t_google_live`: read-only checks
  against Google with a stored profile.

Credentials must never be committed to this repository.
