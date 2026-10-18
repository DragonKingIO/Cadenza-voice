# Maintainer steps: Hugging Face datasets

These steps are for the project owner. Nothing here has been done yet, and the account must be created by you.

## Why two datasets

A gated dataset still lets every approved user download everything in it. Option B (evaluation only, no redistribution) therefore cannot live there.

| Dataset | Holds | Visibility |
| --- | --- | --- |
| `<you>/cadenza-voice-testset` | Option A (CC0) submissions | Public, gated (manual approval) |
| `<you>/cadenza-voice-testset-private` | Option B submissions | Private |

## Create them

1. Sign up at https://huggingface.co and enable two-factor authentication.
2. New dataset, name `cadenza-voice-testset`, license `cc0-1.0`, public. Paste `DATASET_CARD.md` as its `README.md` (the front matter turns on the gate). In the repository settings, set "Gated" to manual approval.
3. New dataset, name `cadenza-voice-testset-private`, **private**, no card needed beyond a short note.
4. Upload `script.json` to the public dataset.

## Handle a submission

1. Receive the zip file (email to {{CONTACT_EMAIL}}). Unzip it in a temporary folder and check `manifest.json`: sentence count, `consent_option` is `A` or `B`, sample rate is 16000.
2. Put the folder under `cc0/<participant_id>/` in the public dataset if the option is A, or in the private dataset if B.
3. Reply to the sender with the participant ID and how to request deletion. Delete the email attachment afterwards.
4. To delete: remove the folder from the dataset and, for A, say plainly that downloaded copies cannot be recalled.

## Before you announce

- Create a dedicated forwarding address (not your personal one) and replace every `{{CONTACT_EMAIL}}` in `docs/testset/`. The recorder page already carries its own contact address, because it has to show one; change it there too if you switch.
- Replace `{{HF_DATASET_URL}}` in the recorder page with the public dataset URL.
- Decide whether to accept submissions through Hugging Face pull requests. Pull request content on a public dataset may be visible to others, so the recorder only suggests that route for option A.
