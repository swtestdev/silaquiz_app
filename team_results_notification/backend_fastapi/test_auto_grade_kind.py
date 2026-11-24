"""Timer auto-grade kind gate (answers_for_selection must be explicit)."""
import unittest

from main import (
    _auto_grade_kind_from_answers_for_selection,
    _coerce_kind_for_expected_slots,
)


class AutoGradeKindTests(unittest.TestCase):
    def test_explicit_modes(self):
        self.assertEqual(_auto_grade_kind_from_answers_for_selection("="), "equals")
        self.assertEqual(
            _auto_grade_kind_from_answers_for_selection("Radio:a;b"),
            "radio",
        )
        self.assertEqual(
            _auto_grade_kind_from_answers_for_selection("List:x;y"),
            "list",
        )

    def test_blank_is_none_for_auto_grade(self):
        self.assertEqual(_auto_grade_kind_from_answers_for_selection(""), "none")
        self.assertEqual(_auto_grade_kind_from_answers_for_selection(None), "none")
        self.assertEqual(
            _auto_grade_kind_from_answers_for_selection("  "),
            "none",
        )

    def test_coerce_does_not_apply_to_auto_grade_helper(self):
        pairs = [(1, "answer")]
        self.assertEqual(_coerce_kind_for_expected_slots("none", pairs), "equals")
        self.assertEqual(_auto_grade_kind_from_answers_for_selection(""), "none")


if __name__ == "__main__":
    unittest.main()
