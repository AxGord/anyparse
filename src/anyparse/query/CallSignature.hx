package anyparse.query;

/** How a call may leave a parameter out. */
enum abstract ParamForm(Int) {

	/** A parameter every call binds. */
	final Plain = 0;

	/** `?p`: a call may leave it out, and its value is nullable (`Null<T>`, 4.3.7 `init_meta_overloads` / `type_function_arg`). */
	final Optional = 1;

	/** `p = v`: a call may leave it out, the default applies; its type stays as written. */
	final Defaulted = 2;

	/** The rest parameter, taking every argument from its position on. */
	final Rest = 3;

}

/** One parameter of a signature: the type it is written with (null for none) and how a call may leave it out. */
typedef SignatureParam = {
	final type: Null<String>;
	final form: ParamForm;
}

/**
 * One signature a call to a function may select (`callUnification.ml`, `unify_field_call`): the function's own, or one an
 * `@:overload` annotation on it writes — its parameters, its written return type, the type parameters it declares, and
 * the offset its types are written at (the function's declaration, or the annotation's function), where they resolve.
 */
typedef CallSignature = {
	final params: Array<SignatureParam>;
	final returnSource: Null<String>;
	final typeParamNames: Array<String>;
	final at: Int;
}
