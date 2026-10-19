package anyparse.core;

/**
 * A map keyed by the IDENTITY of a Doc node — the key a walk over a Doc needs,
 * because a Doc is a DAG: a two-branch ctor's branches share their operands,
 * and those operands nest, so a walk that revisits a shared node pays
 * `2^depth` (`IdentityMap`).
 */
typedef DocIdentityMap<V> = IdentityMap<Doc, V>;
