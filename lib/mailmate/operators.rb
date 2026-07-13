# frozen_string_literal: true

require "date"
require "time"

# Operator evaluator + date arithmetic for MailMate filter expressions.

module Mailmate
  # @api private
  module Operators
    # Compare a single LHS value against a single RHS, applying modifier flags.
    # Returns true/false. lhs may be String, Time/DateTime, Numeric, or
    # Mailmate::Attributes::AddressValue (which to_s renders as "Name <addr>").
    def self.compare(lhs, op, flags, rhs)
      lhs_norm = normalize(lhs, flags)
      rhs_norm = normalize(rhs, flags)

      case op
      when "="  then lhs_norm == rhs_norm
      when "!=" then lhs_norm != rhs_norm
      when "~"  then lhs_norm.to_s.include?(rhs_norm.to_s)
      when "!~" then !lhs_norm.to_s.include?(rhs_norm.to_s)
      when "<", "<=", ">", ">="
        compare_ordered(lhs_norm, op, rhs_norm)
      else
        raise ArgumentError, "unknown operator: #{op.inspect}"
      end
    end

    def self.normalize(v, flags)
      return v if v.is_a?(Time) || v.is_a?(DateTime) || v.is_a?(Numeric)
      s = v.to_s
      s = s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "") if flags.include?("a")
      s = s.downcase if flags.include?("c")
      s
    end

    def self.compare_ordered(lhs, op, rhs)
      lhs_v = coerce_for_ordering(lhs)
      rhs_v = coerce_for_ordering(rhs)
      return false if lhs_v.nil? || rhs_v.nil?
      case op
      when "<"  then lhs_v <  rhs_v
      when "<=" then lhs_v <= rhs_v
      when ">"  then lhs_v >  rhs_v
      when ">=" then lhs_v >= rhs_v
      end
    rescue StandardError
      false
    end

    def self.coerce_for_ordering(v)
      return v.to_time if v.is_a?(DateTime)
      return v if v.is_a?(Time) || v.is_a?(Numeric)
      s = v.to_s
      # Try Time, fall back to Integer
      begin
        return Time.parse(s)
      rescue ArgumentError
      end
      Integer(s) rescue Float(s) rescue nil
    end

    # ---- Date arithmetic ----

    # Resolve a relative date (n units ago) to a Time.
    # `flags` may include "f", which floors to the start of the unit
    # (matches MailMate's >[f] / <[f] semantics).
    def self.relative_date(n, unit, flags = [])
      now = Time.now
      base =
        case unit
        when :day  then now - n * 86_400
        when :week then now - n * 7 * 86_400
        when :month
          y = now.year
          m = now.month - n
          while m <= 0
            m += 12
            y -= 1
          end
          Time.new(y, m, [now.day, last_day_of_month(y, m)].min, now.hour, now.min, now.sec)
        when :year
          Time.new(now.year - n, now.month, now.day, now.hour, now.min, now.sec)
        end

      return base unless flags.include?("f")

      case unit
      when :day
        Time.new(base.year, base.month, base.day)
      when :week
        # Snap to start of ISO week (Monday)
        d = base.to_date
        d -= (d.cwday - 1) # Mon = 1
        Time.new(d.year, d.month, d.day)
      when :month
        Time.new(base.year, base.month, 1)
      when :year
        Time.new(base.year, 1, 1)
      else
        base
      end
    end

    def self.last_day_of_month(y, m)
      Date.new(y, m, -1).day
    end
  end
end
