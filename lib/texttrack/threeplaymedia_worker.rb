# frozen_string_literal: true

require 'faktory_worker_ruby'

require 'connection_pool'
require 'faktory'
require 'securerandom'
require 'speech_to_text'
require 'json'

rails_environment_path =
  File.expand_path(File.join(__dir__, '..', '..', 'config', 'environment'))
require rails_environment_path

module TTS
  class ThreeplaymediaCreateJob # rubocop:disable Style/Documentation
    include Faktory::Job
    faktory_options retry: 5, concurrency: 1

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/AbcSize
    def perform(params_json, id, audio_type)
      params = JSON.parse(params_json, symbolize_names: true)
      u = nil
        
      start_time = Time.now.getutc.to_i
      # TODO
      # Need to handle locale here. What if we want to generate caption
      # for pt-BR, etc. instead of en-US?
      storage_dir = "#{params[:storage_dir]}/#{params[:record_id]}"

      job_name = rand(36**8).to_s(36)
      job_id = SpeechToText::ThreePlaymediaS2T.create_job(
        params[:provider][:auth_file_path],
        "#{storage_dir}/#{params[:record_id]}.#{audio_type}",
        job_name,
        "#{storage_dir}/job_file.json"
      )

      ActiveRecord::Base.connection_pool.with_connection do
        u = Caption.find(id)
        u.update(status: "created job with #{u.service}")
      end

      transcript_id = SpeechToText::ThreePlaymediaS2T.order_transcript(
        params[:provider][:auth_file_path],
        job_id,
        6
      )

      TTS::ThreeplaymediaGetJob.perform_async(params.to_json,
                                              u.id,
                                              job_id,
                                              transcript_id,
                                              start_time)
    end
    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/MethodLength
  end

  class ThreeplaymediaGetJob # rubocop:disable Style/Documentation
    include Faktory::Job
    faktory_options retry: 0, concurrency: 1

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/AbcSize
    def perform(params_json, id, job_id, transcript_id, start_time)
      params = JSON.parse(params_json, symbolize_names: true)
      u = nil

      status = SpeechToText::ThreePlaymediaS2T.check_status(
        params[:provider][:auth_file_path],
        transcript_id
      )
      status_msg = "status is #{status}"
      if status == 'cancelled'
        puts '-------------------'
        puts status_msg
        puts '-------------------'
        ActiveRecord::Base.connection_pool.with_connection do
          u = Caption.find(id)
          u.update(status: 'failed')
        end
        return
      elsif status != 'complete'
        puts '-------------------'
        puts status_msg
        puts '-------------------'

        ThreeplaymediaGetJob.perform_in(30,
                                        params.to_json,
                                        id,
                                        job_id,
                                        transcript_id,
                                        start_time)
        return

      elsif status == 'complete'

        current_time = (Time.now.to_f * 1000).to_i
        SpeechToText::ThreePlaymediaS2T.get_vttfile(
          params[:provider][:auth_file_path],
          139,
          transcript_id,
          "#{params[:storage_dir]}/#{params[:record_id]}",
          "#{params[:record_id]}-#{current_time}-track.vtt"
        )

        SpeechToText::Util.recording_json(
          file_path: "#{params[:storage_dir]}/#{params[:record_id]}",
          record_id: params[:record_id],
          timestamp: current_time,
          language: params[:caption_locale]
        )
          
        end_time = Time.now.getutc.to_i
        processing_time = end_time - start_time
        processing_time =  SpeechToText::Util.seconds_to_timestamp(processing_time)

        ActiveRecord::Base.connection_pool.with_connection do
            u = Caption.find(id)
            u.update(processtime: "#{processing_time}")
        end

        puts '-------------------'
        puts "Processing time: #{processing_time} hr:min:sec.millsec"
        puts '-------------------'

        ActiveRecord::Base.connection_pool.with_connection do
          u.update(status: "done with #{u.service}")
        end

        data = {
          'record_id' => params[:record_id].to_s,
          'storage_dir' => "#{params[:storage_dir]}/#{params[:record_id]}",
          'current_time' => current_time,
          'caption_locale' => (params[:caption_locale]).to_s,
          'bbb_url' => params[:bbb_url],
          'bbb_checksum' => params[:bbb_checksum],
          'kind' => params[:kind],
          'label' => params[:label],
          'id' => id
        }

        TTS::CallbackWorker.perform_async(data.to_json)
      end
    end
    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/MethodLength
  end
end
