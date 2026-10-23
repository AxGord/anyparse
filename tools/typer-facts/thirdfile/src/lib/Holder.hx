package lib;

import lib.Box;
import lib.Item;

class Holder {

	public final items: Array<Item> = [];

	public final box: Box<Item> = new Box<Item>();

	public function new() {}

}
