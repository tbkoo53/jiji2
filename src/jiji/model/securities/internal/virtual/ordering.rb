# frozen_string_literal: true

module Jiji::Model::Securities::Internal::Virtual
  module Ordering
    include Jiji::Errors
    include Jiji::Model::Trading
    include Jiji::Model::Trading::Utils
    include Jiji::Model::Securities::Internal::Utils

    def init_ordering_state(orders = [])
      @orders   = orders
      @order_id = 1
    end

    def order(pair_name, sell_or_buy, units, type = :market, options = {})
      options = Converter.convert_option_to_oanda(options)
      insert_default_options(type, options)
      @order_validator.validate(pair_name, sell_or_buy, units, type, options)
      order = create_order(pair_name, sell_or_buy, units, type, options)
      if order.carried_out?(@current_tick)
        return register_position(order)
      else
        @orders << order
        return OrderResult.new(order.clone, nil, nil, [])
      end
    end

    def retrieve_orders(count = 500, pair_name = nil, max_id = nil)
      @orders.map { |o| o.clone }.sort_by { |o| o.internal_id.to_i * -1 }
    end

    def retrieve_order_by_id(internal_id)
      find_order_by_internal_id(internal_id).clone
    end

    def modify_order(internal_id, options = {})
      options = Converter.convert_option_to_oanda(options)
      order = find_order_by_internal_id(internal_id)
      validate_modify_order_request(order, options)
      MODIFIABLE_PROPERTIES.each do |key|
        snaked = key.to_s.underscore.downcase.to_sym
        new_value = options[key]
        new_value = (order.method(snaked).call || {}).merge(new_value) if new_value.is_a? Hash
        order.method("#{snaked}=").call(Converter.convert_option_value_from_oanda(key, new_value)) if new_value
      end
      order.clone
    end

    def cancel_order(internal_id)
      order = find_order_by_internal_id(internal_id)
      @orders = @orders.reject { |o| o.internal_id == internal_id }
      order.clone
    end

    private

    PROPERTIES = %i[
      timeInForce positionFill triggerCondition
      clientExtensions takeProfitOnFill stopLossOnFill
      trailingStopLossOnFill tradeClientExtensions gtdTime
      priceBound price
    ].freeze

    MODIFIABLE_PROPERTIES = (%i[
      units price
    ] + PROPERTIES).freeze

    def register_position(order)
      position = @position_builder.build_from_order(order,
        @current_tick, account_currency)
      result = close_or_reduce_reverse_positions(position)
      if position.units > 0
        @positions << position
        order.units = position.units
      end
      create_order_result(order, position, result)
    end

    def create_order_result(order, position, result)
      if position.units > 0
        OrderResult.new(nil, position, nil, result[:closed])
      else
        OrderResult.new(nil, nil, result[:reduced], result[:closed])
      end
    end

    def close_or_reduce_reverse_positions(position)
      result = { closed: [], reduced: nil }
      reverse_positions = find_reverse_positions(position)
      reverse_positions.each do |r|
        close_or_reduce_reverse_position(result, r, position)
      end
      remove_closed_positions(result[:closed])
      result
    end

    def remove_closed_positions(closed)
      @positions = @positions.select do |p|
        closed.find do |item|
          p.internal_id == item.internal_id
        end.nil?
      end
    end

    def close_or_reduce_reverse_position(result, reverse_position, position)
      units = position.units
      return unless units > 0

      if reverse_position.units <= units
        result[:closed] << convert_to_closed_position(reverse_position)
        position.units -= reverse_position.units
      else
        reverse_position.units -= units
        position.units = 0
        result[:reduced] = convert_to_reduced_position(reverse_position, units)
      end
    end

    def find_reverse_positions(position)
      @positions.select do |t|
        t.pair_name == position.pair_name \
        && t.sell_or_buy != position.sell_or_buy
      end
    end

    def find_order_by_internal_id(internal_id)
      @orders.find { |o| o.internal_id == internal_id } \
      || error('order not found')
    end

    def update_orders(tick)
      @orders = @orders.reject do |order|
        process_order(tick, order)
      end
    end

    def process_order(tick, order)
      return true if order.expired?(tick.timestamp)

      if order.carried_out?(tick)
        register_position(order)
        true
      else
        false
      end
    end

    def validate_modify_order_request(order, options)
      options = order.collect_properties_for_modify.merge(options).with_indifferent_access
      @order_validator.validate(order.pair_name, order.sell_or_buy,
        options[:units] || order.units, order.type, options)
    end

    def error(message)
      raise OandaApiV20::RequestError, message
    end

    def create_order(pair_name, sell_or_buy, units, type, options)
      order = Jiji::Model::Trading::Order.new(
        pair_name, new_id, sell_or_buy, type, @current_tick.timestamp)
      order.units   = units
      order.price   = resolve_price(
        type, pair_name, sell_or_buy, options, @current_tick)
      init_optional_properties(order, options)
      order
    end

    def new_id
      (@order_id += 1).to_s
    end

    def init_optional_properties(order, options)
      PROPERTIES.each do |key|
        order.send("#{key.to_s.underscore.downcase.to_sym}=",
          Converter.convert_option_value_from_oanda(key, options[key]))
      end
    end

    def insert_default_options(type, options)
      options[:timeInForce] ||= type == :market ? 'FOK' : 'GTC'
      options[:positionFill] ||= 'DEFAULT'
      options[:triggerCondition] ||= 'DEFAULT' if type != :market
    end

    def resolve_price(type, pair_name, sell_or_buy, options, tick)
      return options[:price] || nil if type != :market

      PricingUtils.calculate_entry_price(tick, pair_name, sell_or_buy)
    end

    def convert_to_closed_position(position, units = nil, profit = nil)
      price = PricingUtils.calculate_current_price(
        @current_tick, position.pair_name, position.sell_or_buy)
      ClosedPosition.new(position.internal_id,
        units || position.units, price, @current_tick.timestamp, profit)
    end

    def convert_to_reduced_position(position, units)
      price = PricingUtils.calculate_current_price(
        @current_tick, position.pair_name, position.sell_or_buy)
      ReducedPosition.new(position.internal_id, units,
        price, @current_tick.timestamp, nil)
    end
  end
end
