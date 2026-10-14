# Backup and Restore

Use Settings under Storage to export a complete `.screenloggerbackup` package.
Export takes a consistent SQLite snapshot.
It verifies every managed file before it completes.
It does not change the current Library.

Restore checks the package structure, manifest hashes, schema compatibility,
file paths, and available disk space. It then presents a review.
Only Library replacement pauses capture or changes current data.

Keep backups on storage that is safe for sensitive screenshots.
A backup contains the same private content as the Library.
Screenlogger does not encrypt backups.
The SQLite snapshot includes any derived Related search index.
Downloaded model files and local feature consent are not part of a Library backup.
Restore does not approve a model download or enable Related search.

Do not copy an active SQLite database without its WAL state.
Use the app's export function for a consistent backup.
