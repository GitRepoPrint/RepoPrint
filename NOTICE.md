# Third-party notices

RepoPrint runs unmodified third-party container images. They are pulled from their registries at build time and are not redistributed in this repository.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| Keycloak | 26.8.1 (`quay.io/keycloak/keycloak`) | Apache License 2.0 | https://github.com/keycloak/keycloak |
| PostgreSQL | 17 (`postgres:17-alpine`) | PostgreSQL License | https://www.postgresql.org/about/licence/ |
| Mailpit (development only) | v1.27 (`axllent/mailpit`) | MIT | https://github.com/axllent/mailpit |

The only Keycloak files in this repository are our own configuration: `keycloak/realm-export.json` and the login theme in `keycloak/themes/repoprint/`. The theme extends the stock `keycloak` login theme and adds its own styles, messages and the RepoPrint logo.

If the Keycloak image is ever rebuilt or redistributed (for example a custom production image), include the Apache License 2.0 text and the `NOTICE` and license files shipped inside the Keycloak distribution, and keep them with the image.

The licenses of the backend and frontend dependencies are listed in `docs/MS3/Tech & Frameworks.md`.
