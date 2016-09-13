#
# Copyright (C) 2016-2016, Daniele Orlandi
#
# Author:: Daniele Orlandi <daniele@orlandi.com>
#
# License:: You can redistribute it and/or modify it under the terms of the LICENSE file.
#

require 'ygg/agent/base'

require 'securerandom'
require 'time'

require 'pg'

require 'meteo_recorder/version'
require 'meteo_recorder/task'

module MeteoRecorder

class App < Ygg::Agent::Base
  self.app_name = 'meteo_recorder'
  self.app_version = VERSION
  self.task_class = Task

  def prepare_default_config
    app_config_files << File.join(File.dirname(__FILE__), '..', 'config', 'meteo_recorder.conf')
    app_config_files << '/etc/yggdra/meteo_recorder.conf'
  end

  def agent_boot
    @pg = PG::Connection.open(mycfg.db.to_h)

    @ins_statement = @pg.prepare('insert_meteo',
      'INSERT INTO met_history_entries (ts, record_ts, source, variable, value) ' +
      'VALUES ($1,now(),$2,$3,$4)')

    @amqp.ask(AM::AMQP::MsgExchangeDeclare.new(
      channel_id: @amqp_chan,
      name: mycfg.exchange,
      type: :topic,
      durable: true,
      auto_delete: false,
    )).value

    @amqp.ask(AM::AMQP::MsgQueueDeclare.new(
      channel_id: @amqp_chan,
      name: mycfg.queue,
      durable: true,
      auto_delete: false,
      arguments: {
        :'x-message-ttl' => (3 * 86400 * 1000),
      },
    )).value

    @amqp.ask(AM::AMQP::MsgQueueBind.new(
      channel_id: @amqp_chan,
      queue_name: mycfg.queue,
      exchange_name: mycfg.exchange,
      routing_key: '#'
    )).value

    @msg_consumer = @amqp.ask(AM::AMQP::MsgConsume.new(
      channel_id: @amqp_chan,
      queue_name: mycfg.queue,
      send_to: self.actor_ref,
    )).value.consumer_tag
  end

  def wx_update(message)
    payload = JSON.parse(message.payload).deep_symbolize_keys!

    if !payload[:sample_ts]
      log.info 'Missing sample_ts, ignoring message'
      return
    end

    @pg.transaction do
      if payload[:data][:wind_dir]
        @pg.exec_prepared('insert_meteo', [ payload[:sample_ts], payload[:station_id], 'WIND_DIR', payload[:data][:wind_dir] ])
      end

      if payload[:data][:wind_speed]
        @pg.exec_prepared('insert_meteo', [ payload[:sample_ts], payload[:station_id], 'WIND_SPEED', payload[:data][:wind_speed] ])
      end

      if payload[:data][:qfe]
        @pg.exec_prepared('insert_meteo', [ payload[:sample_ts], payload[:station_id], 'QFE', payload[:data][:qfe] ])
      end

      if payload[:data][:humidity]
        @pg.exec_prepared('insert_meteo', [ payload[:sample_ts], payload[:station_id], 'HUMIDITY', payload[:data][:humidity] ])
      end

      if payload[:data][:temperatur]
        @pg.exec_prepared('insert_meteo', [ payload[:sample_ts], payload[:station_id], 'TEMPERATURE', payload[:data][:temperature] ])
      end
    end
  end


  def actor_handle(message)
    case message
    when AM::AMQP::MsgDelivery

      if message.consumer_tag == @msg_consumer
        case message.headers[:type]
        when 'WX_UPDATE'
          wx_update(message)

          @amqp.tell AM::AMQP::MsgAck.new(channel_id: @amqp_chan, delivery_tag: message.delivery_tag)

        else
          @amqp.tell AM::AMQP::MsgAck.new(channel_id: @amqp_chan, delivery_tag: message.delivery_tag)
        end
      else
        super
      end
    else
      super
    end
  end

end
end
