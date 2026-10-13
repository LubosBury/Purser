import importlib.util
import os
import tempfile
import unittest
from decimal import Decimal

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures", "m3")


def load_tool(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = load_tool("make_spike_csv", "make-spike-csv.py")


def fixture(name):
    return os.path.join(FIXTURES, name)


EXPECTED = (
    "Country,Currency,SpikeYearlyA regular (check),SpikeYearlyA intro PUF 1Y,"
    "SpikeYearlyB regular (check),SpikeYearlyB intro PUF 1Y,SpikeYearlyB free trial days,SpikeMonthly new regular\n"
    "Czechia,CZK,749.00,374.50,999.00,499.50,7,141.90\n"
    "Japan,JPY,3000.00,1500.00,4000.00,2000.00,14,550.00\n"
    "\"Korea, Republic of\",KRW,33000.00,16500.00,44000.00,22000.00,30,6050.00\n"
    "United States,USD,29.99,14.99,39.99,19.99,7,5.49\n"
)


def argv(out, prices_b=("prices-b.json", "prices-b-p2.json")):
    return [
        "--territories", fixture("territories.json"),
        "--names", fixture("names.json"),
        "--prices-a", fixture("prices-a.json"),
        "--prices-b", *[fixture(name) for name in prices_b],
        "--prices-monthly", fixture("prices-monthly.json"),
        "--today", "2026-10-09",
        "--out", out,
    ]


class MakeSpikeCSVTests(unittest.TestCase):
    def test_builds_expected_table(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "nested", "spike.csv")
            self.assertEqual(tool.main(argv(out)), 0)
            with open(out, encoding="utf-8") as f:
                self.assertEqual(f.read(), EXPECTED)

    def test_current_price_skips_future_monthly_and_preserved_rows(self):
        prices = tool.current_regular_prices([tool.load_json(fixture("prices-a.json"))], "2026-10-09")
        self.assertEqual(prices["USA"], Decimal("29.99"))
        self.assertEqual(prices["KOR"], Decimal("33000"))
        self.assertEqual(prices["CZE"], Decimal("749"))
        self.assertEqual(prices["JPN"], Decimal("3000"))

    def test_scheduled_row_becomes_current_on_its_start_date(self):
        prices = tool.current_regular_prices([tool.load_json(fixture("prices-a.json"))], "2026-12-01")
        self.assertEqual(prices["USA"], Decimal("34.99"))

    def test_intro_value_is_rounded_down_and_never_exceeds_half_of_regular(self):
        self.assertEqual(tool.intro_value(Decimal("29.99")), "14.99")
        self.assertEqual(tool.intro_value(Decimal("749")), "374.50")

    def test_missing_page_fails_with_exit_code_2_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "spike.csv")
            self.assertEqual(tool.main(argv(out, prices_b=("prices-b.json",))), 2)
            self.assertFalse(os.path.exists(out))

    def test_storefront_name_wins_over_alias(self):
        names = tool.names_by_code(tool.load_json(fixture("names.json")))
        self.assertEqual(names, {"CZE": "Czechia", "JPN": "Japan", "KOR": "Korea, Republic of", "USA": "United States"})
        only_alias = tool.names_by_code({"version": 1, "storefronts": {}, "aliases": {"Nippon": "JPN"}})
        self.assertEqual(only_alias, {"JPN": "Nippon"})

    def test_name_map_without_storefronts_is_rejected(self):
        with self.assertRaises(tool.SpikeCSVError):
            tool.names_by_code({"Japan": "JPN"})
        with self.assertRaises(tool.SpikeCSVError):
            tool.names_by_code({"version": 1, "storefronts": {"Japan": 392}, "aliases": {}})


if __name__ == "__main__":
    unittest.main()
