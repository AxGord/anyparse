package anyparse.query.cli;

import haxe.Exception;

/**
 * A CLI argument the run cannot use — a flag missing its value, an out-of-range
 * `--limit`, an unknown `--lang` plugin name. Its own type rather than a bare
 * `Exception`, mirroring `WriteFailure`: `Cli.run` catches exactly this (and
 * `WriteFailure`) and nothing else, so an internal bug still surfaces as a raw
 * stack trace — what a bug wants — while a usage mistake gets one sentence on
 * stderr and `EXIT_USAGE` instead.
 */
@:nullSafety(Strict)
final class UsageFailure extends Exception {}
