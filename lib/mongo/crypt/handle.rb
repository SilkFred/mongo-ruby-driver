# frozen_string_literal: true
# encoding: utf-8

# Copyright (C) 2019-2020 MongoDB Inc.
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

require 'ffi'
require 'base64'

module Mongo
  module Crypt

    # A handle to the libmongocrypt library that wraps a mongocrypt_t object,
    # allowing clients to set options on that object or perform operations such
    # as encryption and decryption
    #
    # @api private
    class Handle

      # Creates a new Handle object and initializes it with options
      #
      # @param [ Crypt::KMS::Credentials ] kms_providers Credentials for KMS providers.
      # @param [ Hash ] options A hash of options
      #
      # @option options [ Hash | nil ] :schema_map A hash representing the JSON schema
      #   of the collection that stores auto encrypted documents.
      # @param [ Hash ] kms_tls_options TLS options to connect to KMS
      #   providers. Keys of the hash should be KSM provider names; values
      #   should be hashes of TLS connection options. The options are equivalent
      #   to TLS connection options of Mongo::Client.
      # @option options [ Logger ] :logger A Logger object to which libmongocrypt logs
      #   will be sent
      def initialize(kms_providers, kms_tls_options, options={})
        # FFI::AutoPointer uses a custom release strategy to automatically free
        # the pointer once this object goes out of scope
        @mongocrypt = FFI::AutoPointer.new(
          Binding.mongocrypt_new,
          Binding.method(:mongocrypt_destroy)
        )

        @kms_tls_options =  kms_tls_options

        @schema_map = options[:schema_map]
        set_schema_map if @schema_map

        @logger = options[:logger]
        set_logger_callback if @logger

        set_crypto_hooks

        Binding.setopt_kms_providers(self, kms_providers.to_document)
        initialize_mongocrypt
      end

      # Return the reference to the underlying @mongocrypt object
      #
      # @return [ FFI::Pointer ]
      def ref
        @mongocrypt
      end

      # Return TLS options for KMS provider. If there are no TLS options set,
      # empty hash is returned.
      #
      # @param [ String ] provider KSM provider name.
      #
      # @return [ Hash ] TLS options to connect to KMS provider.
      def kms_tls_options(provider)
        @kms_tls_options.fetch(provider, {})
      end

      private

      # Set the schema map option on the underlying mongocrypt_t object
      def set_schema_map
        unless @schema_map.is_a?(Hash)
          raise ArgumentError.new(
            "#{@schema_map} is an invalid schema_map; schema_map must be a Hash or nil"
          )
        end

        Binding.setopt_schema_map(self, @schema_map)
      end

      # Send the logs from libmongocrypt to the Mongo::Logger
      def set_logger_callback
        @log_callback = Proc.new do |level, msg|
          @logger.send(level, msg)
        end

        Binding.setopt_log_handler(@mongocrypt, @log_callback)
      end

      # Yields to the provided block and rescues exceptions raised by
      # the block. If an exception was raised, sets the specified status
      # to the exception message and returns false. If no exceptions were
      # raised, does not modify the status and returns true.
      #
      # This method is meant to be used with libmongocrypt callbacks and
      # follows the API defined by libmongocrypt.
      #
      # @param [ FFI::Pointer ] status_p A pointer to libmongocrypt status object
      #
      # @return [ true | false ] Whether block executed without raising
      #   exceptions.
      def handle_error(status_p)
        begin
          yield

          true
        rescue => e
          status = Status.from_pointer(status_p)
          status.update(:error_client, 1, "#{e.class}: #{e}")
          false
        end
      end

      # Yields to the provided block and writes the return value of block
      # to the specified mongocrypt_binary_t object. If an exception is
      # raised during execution of the block, writes the exception message
      # to the specified status object and returns false. If no exception is
      # raised, does not modify status and returns true.
      # message to the mongocrypt_status_t object.
      #
      # @param [ FFI::Pointer ] output_binary_p A pointer to libmongocrypt
      #   Binary object to receive the result of block's execution
      # @param [ FFI::Pointer ] status_p A pointer to libmongocrypt status object
      #
      # @return [ true | false ] Whether block executed without raising
      #   exceptions.
      def write_binary_string_and_set_status(output_binary_p, status_p)
        handle_error(status_p) do
          output = yield

          Binary.from_pointer(output_binary_p).write(output)
        end
      end

      # Perform AES encryption or decryption and write the output to the
      # provided mongocrypt_binary_t object.
      def do_aes(key_binary_p, iv_binary_p, input_binary_p, output_binary_p,
        response_length_p, status_p, decrypt: false)
        key = Binary.from_pointer(key_binary_p).to_s
        iv = Binary.from_pointer(iv_binary_p).to_s
        input = Binary.from_pointer(input_binary_p).to_s

        write_binary_string_and_set_status(output_binary_p, status_p) do
          output = Hooks.aes(key, iv, input, decrypt: decrypt)
          response_length_p.write_int(output.bytesize)

          output
        end
      end

      # Perform HMAC SHA encryption and write the output to the provided
      # mongocrypt_binary_t object.
      def do_hmac_sha(digest_name, key_binary_p, input_binary_p,
        output_binary_p, status_p)
        key = Binary.from_pointer(key_binary_p).to_s
        input = Binary.from_pointer(input_binary_p).to_s

        write_binary_string_and_set_status(output_binary_p, status_p) do
          Hooks.hmac_sha(digest_name, key, input)
        end
      end

      # Perform signing using RSASSA-PKCS1-v1_5 with SHA256 hash and write
      # the output to the provided mongocrypt_binary_t object.
      def do_rsaes_pkcs_signature(key_binary_p, input_binary_p,
        output_binary_p, status_p)
        key = Binary.from_pointer(key_binary_p).to_s
        input = Binary.from_pointer(input_binary_p).to_s

        write_binary_string_and_set_status(output_binary_p, status_p) do
          Hooks.rsaes_pkcs_signature(key, input)
        end
      end

      # We are building libmongocrypt without crypto functions to remove the
      # external dependency on OpenSSL. This method binds native Ruby crypto
      # methods to the underlying mongocrypt_t object so that libmongocrypt can
      # still perform cryptography.
      #
      # Every crypto binding ignores its first argument, which is an option
      # mongocrypt_ctx_t object and is not required to use crypto hooks.
      def set_crypto_hooks
        @aes_encrypt = Proc.new do |_, key_binary_p, iv_binary_p, input_binary_p,
          output_binary_p, response_length_p, status_p|
          do_aes(
            key_binary_p,
            iv_binary_p,
            input_binary_p,
            output_binary_p,
            response_length_p,
            status_p
          )
        end

        @aes_decrypt = Proc.new do |_, key_binary_p, iv_binary_p, input_binary_p,
          output_binary_p, response_length_p, status_p|
          do_aes(
            key_binary_p,
            iv_binary_p,
            input_binary_p,
            output_binary_p,
            response_length_p,
            status_p,
            decrypt: true
          )
        end

        @random = Proc.new do |_, output_binary_p, num_bytes, status_p|
          write_binary_string_and_set_status(output_binary_p, status_p) do
            Hooks.random(num_bytes)
          end
        end

        @hmac_sha_512 = Proc.new do |_, key_binary_p, input_binary_p,
          output_binary_p, status_p|
          do_hmac_sha('SHA512', key_binary_p, input_binary_p, output_binary_p, status_p)
        end

        @hmac_sha_256 = Proc.new do |_, key_binary_p, input_binary_p,
          output_binary_p, status_p|
          do_hmac_sha('SHA256', key_binary_p, input_binary_p, output_binary_p, status_p)
        end

        @hmac_hash = Proc.new do |_, input_binary_p, output_binary_p, status_p|
          input = Binary.from_pointer(input_binary_p).to_s

          write_binary_string_and_set_status(output_binary_p, status_p) do
            Hooks.hash_sha256(input)
          end
        end

        Binding.setopt_crypto_hooks(
          self,
          @aes_encrypt,
          @aes_decrypt,
          @random,
          @hmac_sha_512,
          @hmac_sha_256,
          @hmac_hash,
        )

        @rsaes_pkcs_signature_cb = Proc.new do |_, key_binary_p, input_binary_p,
          output_binary_p, status_p|
          do_rsaes_pkcs_signature(key_binary_p, input_binary_p, output_binary_p, status_p)
        end

        Binding.setopt_crypto_hook_sign_rsaes_pkcs1_v1_5(
          self,
          @rsaes_pkcs_signature_cb
        )
      end

      # Initialize the underlying mongocrypt_t object and raise an error if the operation fails
      def initialize_mongocrypt
        Binding.init(self)
        # There is currently no test for the error(?) code path
      end
    end
  end
end
