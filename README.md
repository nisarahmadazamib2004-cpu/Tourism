# Tourism ERP

**Commercial White-Label Tourism / Travel / Umrah ERP Foundation**

A modular foundation for tourism, travel agency and Umrah management businesses.

## Database

Import `database/tourism_erp.sql` into MariaDB/MySQL.

Configure database credentials through:

- `config/database.php`
- Environment variables

Always create and verify a database backup before importing SQL into an existing database.

## Architecture

The codebase is designed with the following architecture:

- Multi-tenant ready.
- Modular application structure.
- Localization-ready.
- Shared global assets.
- Per-module CSS and JavaScript.
- White-label company branding foundation.

## Module Standard

Each business module follows this standard structure:

- `index.php` — Main module listing.
- `view.php` — View record details.
- `edit.php` — Edit records.
- `<module>.css` — Module styling.
- `<module>.js` — Module JavaScript.
- `<module>.html` — Module markup where applicable.

## Security Baseline

The foundation includes:

- PDO prepared statements.
- CSRF protection helpers.
- Session regeneration.
- Output escaping.
- Login isolation.

Security controls should be reviewed and tested across all modules before production deployment.

## Added Core Modules

- `invitations/`
- `foreign_visitors/`
- `permissions/`

All follow the standard module structure:

`index.php`, `view.php`, `edit.php`, `module.css`, `module.js`, and `module.html`.

## Project Status

Commercial white-label ERP foundation. Further development, testing and production validation are required.