package anyparse.check;

/**
 * The one answer to "what type does a lint configuration carry for what the compiler oracle
 * already answered in a run": a marker the oracle's run memo (`OracleRunMemo`) implements,
 * so `OracleConfig` names its run without `anyparse.check` importing `anyparse.check.oracle`.
 */
@:nullSafety(Strict)
interface OracleRunScope {}
