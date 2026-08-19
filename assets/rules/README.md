# CDC constraint rules (Stage 5 design)

This folder will hold the rules files that the offline guided Q&A engine
(Stage 5) checks every proposed lesson-plan adjustment against, before
applying it. The Q&A engine itself doesn't exist yet — this is the data
shape it will consume, fixed now so Stage 5 has something concrete to build
against instead of inventing the format under time pressure later.

One rules file per curriculum (`curriculum_code` matches the `curricula`
table), since what's mandatory can differ between the 2023 CBC and the 2013
OBC. See `cdc_constraints.example.json` for a worked example.

## Shape

```jsonc
{
  "curriculum_code": "CBC_2023",
  "version": 1,

  // Template field keys (see Stage 2's Template Engine) that a Q&A answer
  // can never blank, remove, or leave without content — regardless of what
  // the teacher answers. These map to the CDC template's mandatory
  // sections (Topic, Objectives, TLM, Introduction, Development,
  // Conclusion, Evaluation).
  "locked_template_sections": ["topic", "objectives", "competencies", "evaluation", "conclusion"],

  "rules": [
    {
      "id": "stable-slug-for-logging-and-the-flagged-message",
      "applies_to_field": "activities | group_size | teaching_learning_materials | sub_topic_inclusion | ...",
      "type": "requires_competency_overlap | range | requires_flag_when_condition | locked_if_tagged | preference_hint",
      "severity": "block | warn",
      "description": "Shown to the teacher when this rule fires — plain-language reason.",
      "params": { "...": "shape depends on type, see below" }
    }
  ]
}
```

## Rule `type`s

| `type` | `params` | Meaning |
|---|---|---|
| `requires_competency_overlap` | `{}` | A substituted activity must still map to at least one competency already listed for the topic/sub-topic being planned. Prevents an answer-driven swap from silently dropping what the lesson is meant to teach. |
| `range` | `{"min": n, "max": n}` | A numeric field (e.g. `group_size`) must land inside this range no matter what the driving answer (e.g. class size) implies. |
| `requires_flag_when_condition` | `{"condition_answer_key", "condition_answer_value", "required_activity_tag"}` | If the teacher's answer to `condition_answer_key` equals `condition_answer_value`, only candidates tagged `required_activity_tag` (or on `locked_template_sections`) may be selected. Used for "no teaching aids available" → only aid-free activities. |
| `locked_if_tagged` | `{"tag"}` | An item (e.g. a sub-topic) carrying this tag in the curriculum data can never be skipped or removed by an answer, even one implying high prior mastery. |
| `preference_hint` | `{}` | The answer may re-*order* candidates (e.g. preferred activity style) but never removes the only candidate covering a mandatory competency. Always `severity: "warn"`, never `"block"` — preferences steer, they don't override. |

## `severity`

- **`block`** — the proposed adjustment is not applied; the plan keeps its
  prior/default value for that field, and the teacher sees why (the rule's
  `description`) in a flagged-and-skipped list at the end of the Q&A flow.
- **`warn`** — the adjustment is applied, but surfaced to the teacher as a
  call-out rather than silently accepted.

## Dependency this creates for Stage 2

For `requires_competency_overlap`, `requires_flag_when_condition`, and
`locked_if_tagged` to mean anything, the underlying curriculum data needs
tags to check against — e.g. an activity bank where each activity lists
which competency IDs it covers and whether it needs special aids, and a
`foundational: true` flag on sub-topics that must never be skipped. That
tagging lives in the Template Engine's field definitions (Stage 2), not
here — this file only describes how those tags get *enforced*.
