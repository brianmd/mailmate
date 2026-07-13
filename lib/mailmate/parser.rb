# frozen_string_literal: true

require_relative "ast"
require "time"

# Recursive-descent parser for MailMate filter expressions.
#
# Grammar (informal, top-down):
#   filter      = expr eof
#   expr        = or_expr
#   or_expr     = and_expr ('or' and_expr)*
#   and_expr    = not_expr (('and' | <implicit>) not_expr)*    # implicit AND
#   not_expr    = ['not'] term
#   term        = '(' expr ')'
#               | clause
#   clause      = path 'exists'
#               | path op value
#   path        = (ident | shorthand) ('.' ident)*
#   op          = OP_TOKEN  (carries flags from lexer)
#   value       = string | number | rel_date | abs_date | varref
#   rel_date    = number unit 'ago'        # unit: day(s), week(s), month(s), year(s)
#   abs_date    = string                   # parsed as Time.parse if value contains a date pattern
#   varref      = '$' VAR ('.' (ident|shorthand))*

module Mailmate
  # @api private
  #
  # Filter-language parser. Use `Mailmate.compile_filter` as the public
  # surface.
  class Parser
    class Error < StandardError; end

    UNITS = {
      "day" => :day, "days" => :day,
      "week" => :week, "weeks" => :week,
      "month" => :month, "months" => :month,
      "year" => :year, "years" => :year,
    }.freeze

    DATE_LIKE = /\A\s*\d{4}[-\/.]\d{1,2}([-\/.]\d{1,2}|.*\d{2}:\d{2})/.freeze

    def self.parse(tokens)
      new(tokens).parse_filter
    end

    def initialize(tokens)
      @tokens = tokens
      @i = 0
    end

    def parse_filter
      expr = parse_expr
      expect(:eof)
      expr
    end

    private

    # ---------- token utilities ----------

    def peek(off = 0); @tokens[@i + off]; end
    def consume; t = @tokens[@i]; @i += 1; t; end

    def at?(kind, value = nil)
      t = peek
      return false unless t && t[0] == kind
      value.nil? || t[1] == value
    end

    def expect(kind, value = nil)
      t = peek
      ok = t && t[0] == kind && (value.nil? || t[1] == value)
      raise Error, "expected #{kind}#{value ? " #{value.inspect}" : ""} at #{@i}, got #{t.inspect}" unless ok
      consume
    end

    # ---------- grammar ----------

    def parse_expr
      parse_or
    end

    def parse_or
      left = parse_and
      while at?(:keyword, "or")
        consume
        right = parse_and
        if left.is_a?(AST::OrNode)
          left.children << right
        else
          left = AST::OrNode.new([left, right])
        end
      end
      left
    end

    def parse_and
      left = parse_not
      loop do
        if at?(:keyword, "and")
          consume
          right = parse_not
        elsif implicit_and_continues?
          right = parse_not
        else
          break
        end
        if left.is_a?(AST::AndNode)
          left.children << right
        else
          left = AST::AndNode.new([left, right])
        end
      end
      left
    end

    # Implicit AND only continues if the next token can start a clause/term and
    # we're at the top level. This matches MailMate's "implicit and" between
    # consecutive clauses without an explicit connector.
    def implicit_and_continues?
      t = peek
      return false unless t
      kind = t[0]
      return true if kind == :lparen || kind == :ident || kind == :shorthand
      return true if kind == :keyword && t[1] == "not"
      false
    end

    def parse_not
      if at?(:keyword, "not")
        consume
        AST::NotNode.new(parse_term)
      else
        parse_term
      end
    end

    def parse_term
      if at?(:lparen)
        consume
        e = parse_expr
        expect(:rparen)
        return e
      end
      parse_clause
    end

    def parse_clause
      path = parse_path

      if at?(:keyword, "exists")
        consume
        return AST::ExistsNode.new(path)
      end

      raise Error, "expected operator after path at #{@i}, got #{peek.inspect}" unless at?(:op)
      _, op, flags = consume

      value = parse_value
      AST::CompareNode.new(path, op, flags, value)
    end

    def parse_path
      parts = []
      t = peek
      raise Error, "expected ident or shorthand at #{@i}, got #{t.inspect}" unless t && (t[0] == :ident || t[0] == :shorthand)
      parts << consume[1]
      while at?(:dot)
        consume
        nt = peek
        raise Error, "expected ident or shorthand after '.' at #{@i}, got #{nt.inspect}" unless nt && (nt[0] == :ident || nt[0] == :shorthand)
        parts << consume[1]
      end
      parts
    end

    def parse_value
      t = peek
      case t[0]
      when :var
        var = consume[1]
        path = []
        while at?(:dot)
          consume
          nt = peek
          raise Error, "expected ident or shorthand after '.' in $var path" unless nt && (nt[0] == :ident || nt[0] == :shorthand)
          path << consume[1]
        end
        AST::VarRefNode.new(var, path)
      when :number
        n = consume[1]
        # Possibly a relative date: NUMBER UNIT 'ago'
        if at?(:ident) && UNITS.key?(peek[1])
          unit_word = consume[1]
          if at?(:ident, "ago")
            consume
            return AST::RelativeDateNode.new(n, UNITS[unit_word])
          else
            raise Error, "expected 'ago' after number unit, got #{peek.inspect}"
          end
        end
        AST::NumberNode.new(n)
      when :string
        s = consume[1]
        if s =~ DATE_LIKE
          begin
            return AST::AbsoluteDateNode.new(Time.parse(s))
          rescue ArgumentError
            # fall through to literal string
          end
        end
        AST::LiteralStringNode.new(s)
      else
        raise Error, "expected value at #{@i}, got #{t.inspect}"
      end
    end
  end
end
