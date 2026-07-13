# frozen_string_literal: true

# Lexer for MailMate filter expressions. Emits a flat array of [kind, value]
# tokens. Whitespace is skipped. Keywords (`and`, `or`, `not`, `exists`) are
# recognized at lex time; `ago`, `days`, `months`, etc. stay as :ident and are
# disambiguated by the parser.

module Mailmate
  # @api private
  module Lexer
    KEYWORDS = %w[and or not exists].freeze
    OP_FLAG_CHARS = "cafx" # operator-modifier flags, e.g. =[c], >[f], !=[x]

    class Error < StandardError; end

    def self.lex(input)
      tokens = []
      i = 0
      while i < input.length
        c = input[i]

        # Whitespace
        if c =~ /\s/
          i += 1
          next
        end

        # Punctuation
        if c == "("
          tokens << [:lparen]; i += 1; next
        elsif c == ")"
          tokens << [:rparen]; i += 1; next
        elsif c == "."
          tokens << [:dot]; i += 1; next
        end

        # Variable reference: $SENT, $PERSONAL_INBOX
        if c == "$"
          j = i + 1
          j += 1 while j < input.length && input[j] =~ /[A-Z_]/
          raise Error, "empty variable name at #{i}" if j == i + 1
          tokens << [:var, input[(i + 1)...j]]
          i = j
          next
        end

        # String: '...'  Only `\\` and `\'` are recognized escapes; other
        # backslashes are preserved literally so IMAP keywords like
        # `\Seen` / `\Flagged` survive intact.
        if c == "'"
          j = i + 1
          buf = +""
          while j < input.length && input[j] != "'"
            if input[j] == "\\" && j + 1 < input.length && (input[j + 1] == "\\" || input[j + 1] == "'")
              buf << input[j + 1]
              j += 2
            else
              buf << input[j]
              j += 1
            end
          end
          raise Error, "unterminated string starting at #{i}" if j >= input.length
          tokens << [:string, buf]
          i = j + 1
          next
        end

        # Operator: !=, =, ~, !~, <, <=, >, >=, with optional [flags]
        if "!=~<>".include?(c)
          op = c
          j = i + 1
          if c == "!" && j < input.length && (input[j] == "=" || input[j] == "~")
            op = "!" + input[j]
            j += 1
          elsif (c == "<" || c == ">") && j < input.length && input[j] == "="
            op = c + "="
            j += 1
          end
          # Optional [flags]
          flags = []
          if j < input.length && input[j] == "["
            k = j + 1
            while k < input.length && OP_FLAG_CHARS.include?(input[k])
              flags << input[k]
              k += 1
            end
            raise Error, "expected ] after operator flags at #{j}" if k >= input.length || input[k] != "]"
            j = k + 1
          end
          tokens << [:op, op, flags]
          i = j
          next
        end

        # Number: 0-9+
        if c =~ /\d/
          j = i
          j += 1 while j < input.length && input[j] =~ /\d/
          tokens << [:number, input[i...j].to_i]
          i = j
          next
        end

        # Shorthand: # or ## followed by ident
        if c == "#"
          j = i
          j += 1 while j < input.length && input[j] == "#"
          start = j
          j += 1 while j < input.length && input[j] =~ /[a-zA-Z0-9_-]/
          raise Error, "empty shorthand at #{i}" if start == j
          tokens << [:shorthand, input[i...j]]
          i = j
          next
        end

        # Identifier: [a-zA-Z_][a-zA-Z0-9_-]*
        if c =~ /[a-zA-Z_]/
          j = i
          j += 1 while j < input.length && input[j] =~ /[a-zA-Z0-9_-]/
          word = input[i...j]
          if KEYWORDS.include?(word)
            tokens << [:keyword, word]
          else
            tokens << [:ident, word]
          end
          i = j
          next
        end

        raise Error, "unexpected char #{c.inspect} at position #{i}"
      end
      tokens << [:eof]
      tokens
    end
  end
end
