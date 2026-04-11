package anyparse.format.text;

/**
 * Trailing separator policy after the last entry of a sequence or
 * mapping. JSON uses `Disallowed`; JSON5, ECMAScript object literals
 * and TOML arrays use `Allowed`; no real format currently uses
 * `Required` but it rounds out the space.
 */
enum abstract TrailingSepPolicy(Int) {
	final Allowed = 0;
	final Disallowed = 1;
	final Required = 2;
}
