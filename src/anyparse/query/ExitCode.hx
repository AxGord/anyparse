package anyparse.query;

/**
 * The process exit statuses the CLI returns. `to Int` lets a value flow into any
 * `Int` position — `Sys.exit`, a command handler's `Int` return — so command code
 * keeps reading `EXIT_OK` / `EXIT_USAGE` / `EXIT_RUNTIME` unqualified (through a
 * wildcard import) while the codes now live as one distinct, named type instead of
 * three loose `Int` constants. Values follow the convention the CLI already used:
 * 0 success, 2 usage error, 1 runtime error.
 */
enum abstract ExitCode(Int) to Int {
	final EXIT_OK = 0;
	final EXIT_USAGE = 2;
	final EXIT_RUNTIME = 1;
}
