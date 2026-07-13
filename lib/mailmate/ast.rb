# frozen_string_literal: true

# AST nodes for MailMate filter expressions. All nodes implement #inspect for
# debug output and are evaluated by Mailmate::Evaluator.

module Mailmate
  # @api private
  module AST
    AndNode     = Struct.new(:children) { def inspect; "And(#{children.map(&:inspect).join(", ")})"; end }
    OrNode      = Struct.new(:children) { def inspect; "Or(#{children.map(&:inspect).join(", ")})"; end }
    NotNode     = Struct.new(:child)    { def inspect; "Not(#{child.inspect})"; end }

    # path: array of strings, e.g. ["from", "name"] or ["#any-address"]
    # op: one of "=", "!=", "~", "!~", "<", "<=", ">", ">="
    # flags: array of single-letter strings, e.g. ["c"], ["c", "a"], or []
    # value: a *Node (LiteralStringNode, NumberNode, RelativeDateNode, AbsoluteDateNode, VarRefNode)
    CompareNode = Struct.new(:path, :op, :flags, :value) do
      def inspect; "Compare(#{path.join(".")} #{op}#{flags.empty? ? "" : "[#{flags.join}]"} #{value.inspect})"; end
    end

    ExistsNode = Struct.new(:path) { def inspect; "Exists(#{path.join(".")})"; end }

    LiteralStringNode = Struct.new(:value) { def inspect; "Str(#{value.inspect})"; end }
    NumberNode        = Struct.new(:value) { def inspect; "Num(#{value})"; end }

    # n: integer; unit: :day, :week, :month, :year
    RelativeDateNode = Struct.new(:n, :unit) { def inspect; "Rel(#{n} #{unit}s ago)"; end }
    AbsoluteDateNode = Struct.new(:time)     { def inspect; "Abs(#{time.iso8601})"; end }

    # Stage C placeholder: $SENT.from.address style references.
    VarRefNode = Struct.new(:var, :path) { def inspect; "Var($#{var}.#{path.join(".")})"; end }
  end
end
