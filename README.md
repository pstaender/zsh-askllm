# askllm for zsh

> Vibe coded zsh plugin that lets you ask an LLM for shell commands right at your prompt. It uses OpenAI's API to generate commands based on your questions.

Ask an LLM for shell commands right at your zsh prompt. Any line shorter than 250 characters that ends in one of these suffixes is sent to OpenAI instead of being run:

| Suffix | Behaviour |
|--------|-----------|
| `?`    | One command, put into your prompt (press Enter to run it) |
| `?!`   | One command, executed immediately, unless it looks risky |
| `??`   | Up to 6 numbered commands; press a digit (no Enter needed) to put one into your prompt |
| `??!`  | Same as `??`, but runs the selected command, unless it looks risky |

```
$ see last commit in git?
# Show the latest commit and its changes
$ git show HEAD▌

$ show last commit git??
The following commands can be used:
1. git show HEAD  # Show the latest commit and its changes
2. git log -1 --oneline  # Show the latest commit summary
select 1-2 (any other key cancels):
```

A command counts as risky if the model flags it as having side effects, **or** if a local check matches it (`rm`, `mv`, `>` redirects, `git reset/push/commit`, `sudo`, `find -delete`, `| sh`, `<PLACEHOLDER>`s, …). Risky commands are never run automatically. Instead they go into your prompt with a warning above them.

The question is added to your shell history, and so is every executed command.

## Install

Requires `curl`, `jq` and `OPENAI_ACCESS_TOKEN` in your environment.

```zsh
# plain
source /path/to/askllm/askllm.plugin.zsh
# oh-my-zsh: clone into $ZSH_CUSTOM/plugins/askllm and add `askllm` to plugins=(…)
```

Load it **after** zsh-syntax-highlighting / zsh-autosuggestions. It wraps whatever `accept-line` widget already exists.

## Settings

```zsh
ASKLLM_MODEL=gpt-6-luna                                   # model
ASKLLM_API_URL=https://api.openai.com/v1/chat/completions # any OpenAI-compatible endpoint
ASKLLM_MAX_LEN=250                                        # max line length that counts as a question
ASKLLM_TIMEOUT=30                                         # seconds
ASKLLM_PREFILL=1                                          # 0 = only print the command instead of prefilling the prompt
ASKLLM_DISABLE=1                                          # temporarily turn it off
```

## Running a real command that ends in `?`

- Lines whose last word is a glob that matches existing files (`ls file?`) run normally.
- Otherwise, escape the question mark: `ls foo\?`.
