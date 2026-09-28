"""Offline checks of narrow deterministic boundaries using synthetic text only.

Run from ``brain`` with Python 3.12 or newer:
    python3 -B -S -m unittest discover -s tests -p 'test_offline.py' -v

These tests do not load configuration, models, credentials, or user data.
They describe specific supported forms, not general transcription quality.
"""

import unittest

from core.literal_text import LiteralText
from core.neutral_list_labels import format_after_refinement, normalize
from core.spoken_repetition import repair_demonstrative_restart


class NeutralListLabelsTests(unittest.TestCase):
    def setUp(self):
        self.mixed = (
            "为展台准备三件事：\n"
            "第1件事，整理彩纸。\n"
            "第2个，摆放模型。\n"
            "第3件，核对卡片。\n\n"
            "全部完成后封箱。"
        )

    def test_mixed_punctuated_labels_normalize_without_changing_bodies(self):
        expected = (
            "为展台准备三件事：\n"
            "第一，整理彩纸。\n"
            "第二，摆放模型。\n"
            "第三，核对卡片。\n\n"
            "全部完成后封箱。"
        )
        self.assertEqual(normalize(self.mixed), expected)
        self.assertEqual(format_after_refinement(self.mixed), expected)

    def test_unpunctuated_labels_are_not_forced_into_one_style(self):
        text = self.mixed.replace("事，", "事").replace("个，", "个").replace("件，", "件")
        self.assertEqual(normalize(text), text)
        self.assertEqual(format_after_refinement(text), text)

    def test_incomplete_list_is_unchanged(self):
        text = "准备三件事：\n第1件事，裁好丝带。\n第2个，叠好纸盒。"
        self.assertEqual(normalize(text), text)
        self.assertEqual(format_after_refinement(text), text)

    def test_label_normalization_requires_explicit_three_item_intro(self):
        text = self.mixed.replace("为展台准备三件事：", "展台准备：")
        self.assertEqual(normalize(text), text)

    def test_uniform_labels_are_unchanged(self):
        text = (
            "准备三件事：\n"
            "第一件事，裁好丝带。\n"
            "第二件事，叠好纸盒。\n"
            "第三件事，贴好圆签。"
        )
        self.assertEqual(normalize(text), text)

    def test_literal_source_intent_blocks_candidate_formatting(self):
        source = "请逐字保留行首标签。\n" + self.mixed
        self.assertEqual(normalize(self.mixed, source_text=source), self.mixed)
        self.assertEqual(format_after_refinement(self.mixed, source_text=source), self.mixed)

    def test_quoted_list_is_unchanged(self):
        text = "“" + self.mixed + "”"
        self.assertEqual(normalize(text), text)
        self.assertEqual(format_after_refinement(text), text)

    def test_code_list_is_unchanged(self):
        text = "```text\n" + self.mixed + "\n```"
        self.assertEqual(normalize(text), text)
        self.assertEqual(format_after_refinement(text), text)


class SpokenRepetitionTests(unittest.TestCase):
    def test_two_demonstratives_before_supported_quantity_and_classifier(self):
        for text, expected in (
            ("这这两张图纸需要展平。", "这两张图纸需要展平。"),
            ("把这这3本册子放好。", "把这3本册子放好。"),
            ("这这几件道具留在台上。", "这几件道具留在台上。"),
        ):
            with self.subTest(text=text):
                self.assertEqual(repair_demonstrative_restart(text), expected)

    def test_ordinary_reduplication_and_punctuated_emphasis_are_unchanged(self):
        for text in (
            "小船晃晃悠悠地靠岸，大家看看远处。",
            "纸张真的，真的很薄。",
        ):
            with self.subTest(text=text):
                self.assertEqual(repair_demonstrative_restart(text), text)

    def test_unsupported_shapes_are_unchanged(self):
        for text in (
            "这这这两张图纸需要展平。",
            "这这张图纸需要展平。",
            "这这两幅素描需要装框。",
            "标记A这这两张不能匹配。",
        ):
            with self.subTest(text=text):
                self.assertEqual(repair_demonstrative_restart(text), text)

    def test_punctuation_between_demonstratives_is_preserved(self):
        text = "这，这两张图纸需要展平。"
        self.assertEqual(repair_demonstrative_restart(text), text)

    def test_quoted_and_code_occurrences_are_preserved(self):
        for text in (
            "“这这两张图纸”",
            "`这这两张图纸`",
            "```text\n这这两张图纸\n```",
        ):
            with self.subTest(text=text):
                self.assertEqual(repair_demonstrative_restart(text), text)

    def test_source_quote_still_protects_candidate_that_lost_quotation_marks(self):
        source = "展签写着“这这两张图纸”。"
        candidate = "展签写着这这两张图纸。"
        self.assertEqual(repair_demonstrative_restart(candidate, source=source), candidate)

    def test_explicit_verbatim_intent_is_preserved(self):
        text = "请逐字写出这这两张图纸。"
        self.assertEqual(repair_demonstrative_restart(text), text)


class LiteralTextTests(unittest.TestCase):
    def test_quotes_and_code_round_trip_exactly(self):
        for text in (
            "标牌写着“蓝色一二三”，旁边写着『七八九』。",
            'A "colored sample" and a \'plain sample\'.',
            "行内 `alpha_12 = 7` 保留。",
            "~~~text\nalpha_12 = 7\n~~~",
        ):
            with self.subTest(text=text):
                held = LiteralText(text)
                self.assertTrue(held.has_literals)
                self.assertNotEqual(held.masked, text)
                self.assertEqual(held.restore(held.masked), text)

    def test_synthetic_addresses_and_paths_round_trip_without_access(self):
        for literal in (
            "https://example.invalid/demo?a=7",
            "reader@example.invalid",
            "/synthetic/project/note.txt",
            "sample-note.txt",
        ):
            with self.subTest(literal=literal):
                held = LiteralText("参考 " + literal + " 结束")
                self.assertTrue(held.has_literals)
                self.assertNotIn(literal, held.masked)
                self.assertEqual(held.restore(held.masked), "参考 " + literal + " 结束")

    def test_plain_text_does_not_create_literal_regions(self):
        text = "桌上摆着三盒彩色积木。"
        held = LiteralText(text)
        self.assertFalse(held.has_literals)
        self.assertEqual(held.masked, text)
        self.assertEqual(held.restore(held.masked), text)

    def test_existing_private_use_characters_do_not_collide_with_tokens(self):
        text = "原符号\ue000\ue010\ue001，另有“蓝色纸片”。"
        held = LiteralText(text)
        self.assertTrue(held.has_literals)
        self.assertEqual(held.restore(held.masked), text)

    def test_restore_keeps_literals_when_only_surrounding_text_changes(self):
        held = LiteralText("旧说明：“彩色一二三”。")
        candidate = held.masked.replace("旧说明", "新说明")
        self.assertEqual(held.restore(candidate), "新说明：“彩色一二三”。")


if __name__ == "__main__":
    unittest.main()
