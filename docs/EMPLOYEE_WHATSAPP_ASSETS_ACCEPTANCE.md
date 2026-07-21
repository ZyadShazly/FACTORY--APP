# Acceptance checklist

- [x] Migration reviewed before application.
- [x] Legacy employee rows preserved.
- [x] New employee phone required and normalized.
- [x] Duplicate normalized phone blocked.
- [x] Asset issuance blocked without a valid employee phone.
- [x] Phone snapshotted onto the custody assignment.
- [x] Internal normalization helper removed from API roles.
- [ ] Frontend WhatsApp share consumes the RPC-returned phone.
- [ ] Repository tests and build pass.
- [ ] Vercel check passes.
- [ ] Regression across employees, assets, payroll, and auth passes.
