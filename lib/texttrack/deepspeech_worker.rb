# frozen_string_literal: true

require 'faktory_worker_ruby'

require 'connection_pool'
require 'faktory'
require 'securerandom'
require 'speech_to_text'
require 'sqlite3'
rails_environment_path =
  File.expand_path(File.join(__dir__, '..', '..', 'config', 'environment'))
require rails_environment_path

module TTS
  # rubocop:disable Naming/ClassAndModuleCamelCase
  class DeepspeechCreateJob # rubocop:disable Style/Documentation
    include Faktory::Job
    faktory_options retry: 0, concurrency: 1

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/AbcSize
    def perform(params_json, id, audio_type)
      params = JSON.parse(params_json, symbolize_names: true)
      u = nil
      ActiveRecord::Base.connection_pool.with_connection do
        u = Caption.find(id)
        u.update(status: 'finished audio conversion')
      end

      temp_dir = "#{params[:temp_storage]}/#{params[:record_id]}"
        
      job_name = rand(36**8).to_s(36)
      job_id = SpeechToText::MozillaDeepspeechS2T.create_job(
        "#{temp_dir}/#{params[:record_id]}.#{audio_type}",
        params[:provider][:auth_file_path],
        "#{temp_dir}/#{job_name}_jobdetails.json"
      )
      
      ActiveRecord::Base.connection_pool.with_connection do
        u.update(status: "created job with #{u.service}")
      end

      TTS::DeepspeechGetJob.perform_async(params.to_json, u.id, job_id, job_name)
    end
    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/MethodLength
  end
  # rubocop:enable Naming/ClassAndModuleCamelCase

  # rubocop:disable Naming/ClassAndModuleCamelCase
  class DeepspeechGetJob # rubocop:disable Style/Documentation
    include Faktory::Job
    faktory_options retry: 0, concurrency: 1

    # rubocop:disable Metrics/MethodLength
    def perform(params_json, id, job_id, job_name) # rubocop:disable Metrics/AbcSize
      params = JSON.parse(params_json, symbolize_names: true)
      u = nil
      ActiveRecord::Base.connection_pool.with_connection do
        u = Caption.find(id)
        u.update(status: "waiting on job from #{u.service}")
      end

      auth_file_path = params[:provider][:auth_file_path]
        
      status = SpeechToText::MozillaDeepspeechS2T.checkstatus(job_id,
                                                              auth_file_path)
      if status != 'completed'
          puts '-------------------'
          puts "status is #{status}"
          puts '-------------------'
          puts "#{job_id}"
          puts '-------------------'
          if status['message'] == 'No jobID found'
            puts 'Job does not exist'
            ActiveRecord::Base.connection_pool.with_connection do
                u.update(status: "failed")
            end
            return
          end
          
          #break if status['message'] == 'No jobID found'
          DeepspeechGetJob.perform_in(30, params.to_json, id, job_id, job_name)
          return
      end

      callback_json =
        SpeechToText::MozillaDeepspeechS2T.order_transcript(job_id,
                                                            auth_file_path)
        
      ActiveRecord::Base.connection_pool.with_connection do
        u.update(status: "writing subtitle file from #{u.service}")
      end

      myarray =
        SpeechToText::MozillaDeepspeechS2T.create_mozilla_array(callback_json)

      current_time = (Time.now.to_f * 1000).to_i

      temp_dir = "#{params[:temp_storage]}/#{params[:record_id]}"
      temp_track_vtt = "#{params[:record_id]}-#{current_time}-track.vtt"
      temp_track_json = "#{params[:record_id]}-#{current_time}-track.json"

      SpeechToText::Util.write_to_webvtt(
        vtt_file_path: temp_dir.to_s,
        vtt_file_name: temp_track_vtt.to_s,
        myarray: myarray
      )

      SpeechToText::Util.recording_json(
        file_path: temp_dir.to_s,
        record_id: params[:record_id],
        timestamp: current_time,
        language: params[:caption_locale]
      )

      ActiveRecord::Base.connection_pool.with_connection do    
        u.update(status: "done with #{u.service}")
      end

      File.delete("#{temp_dir}/#{job_name}_jobdetails.json")

      FileUtils.mv("#{temp_dir}/#{temp_track_vtt}",
                   "#{params[:captions_inbox_dir]}/inbox",
                   verbose: true)
      # , :force => true)

      FileUtils.mv("#{temp_dir}/#{temp_track_json}",
                   "#{params[:captions_inbox_dir]}/inbox",
                   verbose: true)
      # , :force => true)

      FileUtils.remove_dir(temp_dir.to_s)
        
      TTS::PlaybackWorker.perform_async(params.to_json,
                                        temp_track_vtt,
                                        temp_track_json,
                                        "#{params[:captions_inbox_dir]}/inbox")
    end
    # rubocop:enable Metrics/MethodLength
  end
  # rubocop:enable Naming/ClassAndModuleCamelCase
end
