package anyparse.ds;

/**
 * A set of values of a fixed domain held as bits — the one answer to "a set of enum values" for the project. `E` is an
 * enum whose constructors take no arguments (a value's bit is its constructor index) or an `Int` enum abstract whose
 * values are non-negative literals (a value's bit is its rank among the distinct values in ascending order, which is the
 * value itself when they run 0 to n - 1, so a sparse set of codes or flags still takes one bit each). Any other `E` is
 * refused at compile time: a domain that is not fixed has no bit to give a value.
 *
 * Each `Bits<E>` is lowered to an abstract of its own by `BitsBuilder`: over one `Int` for a domain of at most 32 values,
 * over a `haxe.ds.Vector<Int>` above. Either way it is a VALUE: an assignment copies it, `add` and `remove` change only the
 * variable they are called on (so a `final` one cannot change), and `|`, `&`, `~` build a new set. `~` stays inside the
 * domain. Iteration visits the members in ascending bit order. A value, or an array of values, converts to a set.
 */
@:genericBuild(anyparse.ds.BitsBuilder.build())
class Bits<E> {}
