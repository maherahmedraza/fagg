# fagg (File Content Aggregator)

**fagg** is a powerful and safe CLI tool designed to recursively scan directories and aggregate file contents into a single file. It is optimized for feeding project context to Large Language Models (LLMs), performing code reviews, or creating project documentation snapshots.

## 🚀 Key Features

- **Read-Only Safety**: Specifically designed to NEVER modify your source files.
- **Filtering**: Whitelist/blacklist by extension, exclude directories, or use glob patterns.
- **Smart Limits**: Set maximum file size, token budgets, or cap lines per file.
- **Git Integration**: Respects your \.gitignore\ rules automatically.
- **Interactive Mode**: Select files visually using \zf\.
- **Multiple Formats**: Output as plain text, Markdown (with syntax highlighting), or JSON.
- **LLM Ready**: Built-in token estimation and output splitting to stay within context limits.

## 🛠 Installation

1. Download the \ggregator.sh\ script.
2. Make it executable:
   \\\ash
   chmod +x aggregator.sh
   \\3. (Optional) Alias it for easy access:
   \\\ash
   alias fagg='./aggregator.sh'
   \\
## 📖 Usage Examples

### Basic Aggregation
\\\ash
./aggregator.sh ./my-project output.txt
\\
### Markdown Output for AI Context
\\\ash
./aggregator.sh ./src context.md -f markdown --tree --toc --stats --tokens
\\
### Stay Within Token Budget
\\\ash
./aggregator.sh ./project output.txt --max-tokens 50000
\\
### Interactive Selection
\\\ash
./aggregator.sh ./project output.txt --interactive
\\
## 📄 License

This project is licensed under the MIT License.
