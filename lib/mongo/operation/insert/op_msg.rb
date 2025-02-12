# frozen_string_literal: true
# encoding: utf-8

# Copyright (C) 2018-2020 MongoDB Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Mongo
  module Operation
    class Insert

      # A MongoDB insert operation sent as an op message.
      #
      # @api private
      #
      # @since 2.5.2
      class OpMsg < OpMsgBase
        include Idable
        include BypassDocumentValidation
        include ExecutableNoValidate
        include ExecutableTransactionLabel
        include PolymorphicResult

        private

        def get_result(connection, context, options = {})
          # This is a Mongo::Operation::Insert::Result
          Result.new(*dispatch_message(connection, context), @ids)
        end

        def selector(connection)
          {
            insert: coll_name,
            Protocol::Msg::DATABASE_IDENTIFIER => db_name,
            ordered: ordered?,
            comment: spec[:comment],
          }.compact
        end

        def message(connection)
          section = Protocol::Msg::Section1.new(IDENTIFIER, send(IDENTIFIER))
          Protocol::Msg.new(flags, { validating_keys: true }, command(connection), section)
        end
      end
    end
  end
end
