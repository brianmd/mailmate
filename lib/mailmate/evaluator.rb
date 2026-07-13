# frozen_string_literal: true

require_relative "ast"
require_relative "attributes"
require_relative "operators"

# Evaluator: walks a parsed AST and tests it against a Mail::Message or
# Mailmate::Message. `var_resolver` is required if the AST contains
# VarRefNode (i.e. `$SENT.foo`, `$PERSONAL_INBOX.foo` etc.).

module Mailmate
  # @api public
  class Evaluator
    def initialize(filter_ast, var_resolver: nil)
      @ast = filter_ast
      @var_resolver = var_resolver
    end

    def matches?(message)
      eval_node(@ast, message)
    end

    private

    def eval_node(node, message)
      case node
      when AST::AndNode then node.children.all? { |c| eval_node(c, message) }
      when AST::OrNode  then node.children.any? { |c| eval_node(c, message) }
      when AST::NotNode then !eval_node(node.child, message)
      when AST::ExistsNode
        v = Attributes.resolve(message, node.path)
        !(v.nil? || (v.respond_to?(:empty?) && v.empty?))
      when AST::CompareNode
        eval_compare(node, message)
      else
        raise "unhandled node: #{node.class}"
      end
    end

    # Multi-value path semantics:
    #   `path = X`     → ANY value equals X
    #   `path ~ X`     → ANY value contains X
    #   `path != X`    → NO value equals X
    #   `path !~ X`    → NO value contains X
    #   `path < X` etc → ANY value compares
    #
    # When the RHS is a `$VAR.attr` reference, RHS becomes a *set* of values;
    # the operator then asks whether any LHS × any RHS satisfies. Negation
    # still inverts the positive form.
    def eval_compare(node, message)
      lhs_values = Array(Attributes.resolve(message, node.path)).compact
      rhs_values = resolve_value_set(node.value, node.flags, message)

      pos_op = positive_op(node.op)
      positive_match = lhs_values.any? do |l|
        rhs_values.any? { |r| Operators.compare(l, pos_op, node.flags, r) }
      end

      negated_op?(node.op) ? !positive_match : positive_match
    end

    def positive_op(op)
      case op
      when "!=" then "="
      when "!~" then "~"
      else op
      end
    end

    def negated_op?(op)
      op == "!=" || op == "!~"
    end

    # Resolve the AST's RHS value to an array of comparable values.
    # Bare values become a one-element array; VarRefNode delegates to the
    # var_resolver, which returns the full set.
    def resolve_value_set(value_node, op_flags, _message)
      case value_node
      when AST::LiteralStringNode then [value_node.value]
      when AST::NumberNode        then [value_node.value]
      when AST::AbsoluteDateNode  then [value_node.time]
      when AST::RelativeDateNode  then [Operators.relative_date(value_node.n, value_node.unit, op_flags)]
      when AST::VarRefNode
        unless @var_resolver
          raise "Filter contains $#{value_node.var} but no var_resolver was provided"
        end
        @var_resolver.resolve(value_node.var, value_node.path)
      else
        raise "unhandled value: #{value_node.class}"
      end
    end
  end
end
