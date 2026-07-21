# App Shell Refactor Acceptance

This sprint reduces `src/App.jsx` gradually without changing user-visible behavior.

## First extraction boundary

- Authentication gate and authentication error mapping
- Application page metadata and navigation constants
- Data-loading helpers that do not render module UI

## Safety rules

- No database migration or production data change
- No broad rewrite of feature modules
- Existing routes, permissions, demo modes, and external asset-confirmation links remain compatible
- Every extraction must preserve imports through a reviewed compatibility boundary
- `npm test` and `npm run build` must leave all tracked files unchanged

## Regression boundaries

- Authentication and profile bootstrap
- Navigation and role-based page visibility
- Projects, payroll, inventory, procurement, production, assets, and work calendar
- External asset confirmation links
- Vercel deployment
