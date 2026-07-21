# Employee WhatsApp custody notifications

- Every newly created employee must have a unique WhatsApp-capable phone number.
- Existing legacy rows remain readable and are not rewritten automatically.
- Updating a legacy phone validates and normalizes it to digits only.
- Asset custody issuance is blocked when the selected active employee has no valid phone.
- The assignment snapshots the employee phone at issuance so later profile edits do not rewrite history.
- The issuance RPC returns the snapshot phone with the confirmation token for the WhatsApp share flow.
- No SMS provider is used.
