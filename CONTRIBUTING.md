# Contributing to SQL Server performance diagnostics

Issues and pull requests are welcome. For anything beyond a small fix, open an issue first so the approach can be agreed before you spend time on it.

## Reporting a problem

Include:

- SQL Server version and edition (`SELECT @@VERSION;`), and whether it is SQL Server, Azure SQL Managed Instance or Azure SQL Database.
- The analysed database's compatibility level and its `LEGACY_CARDINALITY_ESTIMATION` setting.
- The procedure or `ComparePlans_v1.py` command, its exact parameters, and the full output or error text.

Remove anything private before posting: server, instance, database, login and object names, and data values. Query plans (`.sqlplan`) and Query Store output contain object names and the literal parameter values a query ran with, so remove those or describe the plan instead of attaching it.

## Pull requests

- Branch from `main` and keep one change per pull request.
- Say what changed and why, and list every test you ran with its result. A test that was not run is not reported as passed.
- Update the documentation in the same pull request when behaviour changes.
- Keep each file's existing encoding and line endings.

## Rules every change keeps

- The diagnostics only read. A suggested fix is emitted as commented-out text and is never run against the analysed database.
- Integrated or Entra authentication only: no passwords, connection strings or stored credentials.
- `plan_extract.py` is vendored verbatim from Erik Darling's `extract.py`; a change to it belongs upstream, not here.

## Tests

Each stored procedure is held to cell-for-cell identical output with a stand-alone script, and is swept across every compatibility level from 100 through 170 with legacy cardinality estimation off and on. Those scripts and test runners are maintained privately and are not part of this release, so the maintainer runs them before a change is accepted. An accepted change may therefore be applied by the maintainer rather than merged exactly as submitted. In your pull request, say what you ran, on which SQL Server version and at which compatibility levels.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE) that covers this project.
