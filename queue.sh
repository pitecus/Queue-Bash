#!/bin/bash

# Internal variables.
SLEEP="2"
CONCURRENT_THREAD_ENABLE="no"

# Folders names:
FOLDER_QUEUES="queues"
FOLDER_RUNNING="running"
FOLDER_LOGS="logs"
FOLDER_DONE="done"

# Load the ssh deploy command into a variable.
read -r -d "" SSH_DEPLOY_COMMAND <<EOF
# Setup environment
# TODO: replace with your setup script. If you do not have one, comment out the line
[ -e "/etc/setup_env" ]  && source /etc/setup_env;

# Take the server out of rotation.
# TODO: Some servers does not have the rotate-command, so I check if the command exists first.
if [ -e "/usr/sbin/rotate-command" ]
then
	echo "Take the server out of rotation"
	sudo /usr/sbin/rotate-command out
	if [ "\${?}" -ne "0" ]
	then
		echo "error: failed to take the server out of rotation"
		exit -1
	fi
else
	echo "info: application /usr/sbin/rotate-command does not exist"
fi

# Execute the install application
# TODO: change for the package manager that you use.
yum install -y "%s" < /dev/null
if [ "\${?}" -ne "0" ]
then
	echo "error: failed to install package [%s]"
	exit -1
fi

# Put the server back to rotation.
if [ -e "/usr/sbin/rotate-command" ]
then
	echo "Put the server back to rotation"
	sudo /usr/sbin/rotate-command in
	if [ "\${?}" -ne "0" ]
	then
		echo "error: failed to put the server back to rotation"
		exit -1
	fi
fi
EOF

# List of Parameters:
#
# Param1: List of hosts, comma separated.
# Param2: List of packages, comma separated.
# Param3: Deployer User.
# Param4: Queue size

# Define variables.
SSHKEY="/root/.ssh/super_secret_key.key"
if [ ! -e "${SSHKEY}" ]
then
	echo "[error] SSH key file '${SSHKEY}' not found."
	exit 1
fi

# A nice print function.
function queue_bash_print() {
	printf "[%s] [%-5s] [%s] %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "${1}" "${2}" "${3-}"
	#print "${1}" "[${2}] ${3-}"
} # end queue_bash_print

# Show the help message on how to use the script.
function queue_bash_help() {
	echo "Usage:"
	echo "	${0} <hosts> <packages> <user to deploy> <queue size>"
	echo ""
	echo "Queue size 0: single thread"
	echo "Queue size > 0: how many concurrent tasks processing each queue"
	exit 1
} # end queue_bash_help

# Create the required folders and remore files from previous execution.
function queue_bash_startup() {
	queue_bash_print "info" "core" "Start up fresh."

	# Create folders.
	mkdir -p {"${FOLDER_QUEUES}","${FOLDER_RUNNING}","${FOLDER_LOGS}","${FOLDER_DONE}"}
	if [ "${?}" -ne "0" ]
	then
		queue_bash_print "error" "core" "Not able to create initial queue folders."
		exit -1
	fi

	# Remove previous execution files.
	rm -rf {"${FOLDER_QUEUES}","${FOLDER_RUNNING}","${FOLDER_LOGS}","${FOLDER_DONE}"}/*
} # end _queue_bash_startup

function queue_bash_folder_queue() {
	local _queue_name="${1}"
	echo "${FOLDER_QUEUES}/${_queue_name}"
} # end queue_bash_folder_queue

function queue_bash_folder_running() {
	local _queue_name="${1}"
	echo ""${FOLDER_RUNNING}/${_queue_name}""
} # end queue_bash_folder_running

function queue_bash_file_task() {
	local _queue_name="${1}"
	local _task="${2}"
	echo "${FOLDER_QUEUES}/${_queue_name}/${_task}.txt"
} # end queue_bash_file_task

function queue_bash_file_log() {
	local _task="${1}"
	echo "${FOLDER_LOGS}/${_task}.log"
} # end queue_bash_file_log

function queue_bash_file_running() {
	local _queue_name="${1}"
	local _task="${2}"
	echo "${FOLDER_RUNNING}/${_queue_name}/${_task}.run"
} # queue_bash_file_running

function queue_bash_file_success() {
	local _task="${1}"
	echo "${FOLDER_DONE}/${_task}-success.txt"
} # queue_bash_file_success

function queue_bash_file_fail() {
	local _task="${1}"
	echo "${FOLDER_DONE}/${_task}-fail.txt"
} # queue_bash_file_fail

# Create the tasks to be processed by the workers, with the hostname as filename and the packages as content in one line.
function queue_bash_core_tasks() {
	local _build_instances="${1}"
	local _build_packages="${2}"
	queue_bash_print "debug" "core" "queue_bash_core_tasks params: _build_instances=[${_build_instances}], _build_packages=[${_build_packages}]"

	for host in ${_build_instances}
	do
		# Identify the queue name.
		IFS="." read -a host_array <<<"${host}"
		local _queue_name="${host_array[0]/[0-9]*/}-${host_array[2]}"
		local _task_name="${host//\./_}"

		# Create folders for queues.
		local _folder_queue="$(queue_bash_folder_queue "${_queue_name}")"
		if [ ! -d "${_folder_queue}" ]
		then
			queue_bash_print "debug" "core" "create queue [${_folder_queue}]"

			# Create queue folder.
			mkdir -p "${_folder_queue}"
			if [ "${?}" -ne "0" ]
			then
				queue_bash_print "error" "core" "Can not create folder ${_folder_queue}"
				exit 1
			fi
		fi

		# Create folder for running workers.
		local _folder_running="$(queue_bash_folder_running "${_queue_name}")"
		if [ ! -d "${_folder_running}" ]
		then
			queue_bash_print "debug" "core" "create running queue [${_folder_running}]"

			# Create running folder.
			mkdir -p "${_folder_running}"
			if [ "${?}" -ne "0" ]
			then
				queue_bash_print "error" "core" "Can not create folder ${_folder_running}"
				exit 1
			fi
		fi

		# Create file with task.
		local _file_task="$(queue_bash_file_task "${_queue_name}" "${_task_name}")"
		queue_bash_print "debug" "core" "create task [${_file_task}]"
		echo "${_build_packages}" | tr "," " " > "${_file_task}"
		if [ "${?}" -ne "0" ]
		then
			queue_bash_print "error" "core" "Can not create task ${_file_task}"
			exit 1
		fi
	done
} # end queue_bash_core_tasks

# Start the queues managers to start processing the queues.
# Run one task first for "canary" purposes.
function queue_bash_core_queues() {
	local _build_queue_size="${1}"
	local _build_deployer="${2}"
	queue_bash_print "debug" "core" "queue_bash_core_queues params: _build_queue_size=[${_build_queue_size}], _build_deployer=[${_build_deployer}]"

	# Get a list of available queues.
	pushd "${FOLDER_QUEUES}" > /dev/null
	local _queues=""
	for _temp in *
	do
		if [ -d "${_temp}" ]
		then
			_queues="${_queues} ${_temp}"
		fi
	done
	popd > /dev/null
	_queues="${_queues/ /}"
	queue_bash_print "debug" "core" "create managers for queues [${_queues}]"

	# Check how many managers and workers to create.
	if [ "${_build_queue_size}" -eq 0 ]
	then
		# Only one queue manager and 1 worker.
		queue_bash_print "debug" "core" "single queue manager"
		queue_bash_manager "${_queues}" "1" "${_build_deployer}" &
	else
		# Multiple queues, retrieve first queue.
		local _queue="${_queues// */}"
		queue_bash_print "debug" "core" "first queue [${_queue}]"

		# Retrieve the first task.
		local _tasks="$(queue_bash_manager_tasks "${_queue}")"
		local _task="${_tasks// */}"
		queue_bash_print "debug" "core" "first task [${_queue}]/[${_task}]"

		# Retrieve the run file name.
		local _file_run="$(queue_bash_file_running "${_queue}" "${_task}")"
		echo "Queue: ${_queue}" > "${_file_run}"

		# Call the worker (in foreground).
		queue_bash_worker "${_queue}" "${_task}" &

		# Wait until the job is done.
		local _count="$(queue_bash_worker_count "${_queue}")"
		while [ "${_count}" -ne "0" ]
		do
			# Sleep waiting for workers finish their work.
			sleep "${SLEEP}"

			# Get the latest workers count.
			_count="$(queue_bash_worker_count "${_queue}")"
		done

		# Enable concurrent threads.
		CONCURRENT_THREAD_ENABLE="yes"

		# Call the queue managers.
		queue_bash_print "debug" "core" "multiple queue workers"
		queue_bash_print "debug" "core" "queue size is ${_build_queue_size}"
		for _queue in ${_queues}
		do
			queue_bash_print "debug" "core" "queue manager for ${_queue}"
			queue_bash_manager "${_queue}" "${_build_queue_size}" "${_build_deployer}" &
		done
	fi
} # end queue_bash_core_queues

# Create a limited amount of workers and keep them busy.
function queue_bash_manager() {
	local _queue_name="${1}"
	local _queue_cores="${2}"
	queue_bash_print "debug" "manager" "queue_bash_manager params: _queue_name=[${_queue_name}], _queue_cores=[${_queue_cores}]"

	# If multiple queues are passed, they should be processed one at the time.
	for _queue in ${_queue_name}
	do
		# Queue being processed.
		queue_bash_print "info" "manager" "Process queue [${_queue}]"

		# Retrieve the list of tasks.
		local _tasks="$(queue_bash_manager_tasks "${_queue}")"
		queue_bash_print "info" "manager" "Tasks to be processed [${_queue}]/[${_tasks}]"

		# Workers in the queue.
		for _task in ${_tasks}
		do
			# Check for queue size, sleep while full.
			local _count="$(queue_bash_worker_count "${_queue}")"
			while [ "${_count}" -ge "${_queue_cores}" ]
			do
				# Sleep waiting for workers finish their work.
				sleep "${SLEEP}"

				# Get the latest workers count.
				_count="$(queue_bash_worker_count "${_queue}")"
			done

			# Check for failed jobs.
			local _failed="$(ls "${FOLDER_DONE}"/*"-fail.txt" 2> /dev/null | wc -l | sed "s/ //g")"
			if [ "${_failed}" -gt "0" ]
			then
				# Show the skipped tasks.
				queue_bash_print "error" "manager" "Failed tasks found, skipping queue=[${_queue}], task=[${_task}]."
			else
				# Print the message.
				queue_bash_print "info" "manager" "Task to be processed queue=[${_queue}], task=[${_task}]"

				# Create a new worker.
				queue_bash_print "info" "manager" "Create worker for queue=[${_queue}], task=[${_task}]"
				local _file_run="$(queue_bash_file_running "${_queue}" "${_task}")"
				echo "Queue: ${_queue}" > "${_file_run}"

				# Call the worker.
				queue_bash_worker "${_queue}" "${_task}" &
			fi
		done

		# Wait for the jobs to finish.
		queue_bash_print "info" "manager" "Wait for the Queue Managers to finish"
		local _fail="0"
		for _job in $(jobs -p)
		do
			wait ${_job} || let "_fail = ${_fail} + 1"
		done

		# Check for errors.
		if [ "${_fail}" -ne "0" ]
		then
			queue_bash_print "error" "manager" "${_fail} Queue Managers finished with errors"
			exit -1
		fi

		queue_bash_print "info" "manager" "Run succesfull"
	done

	# Finish the process.
	exit 0
} # end queue_bash_manager

function queue_bash_manager_tasks() {
	local _queue_name="${1}"

	# List of tasks.
	local _tasks=""
	# Retrieve the list of tasks.
	pushd "${FOLDER_QUEUES}/${_queue_name}" > /dev/null
	for _task in *.txt
	do
		if [ -f "${_task}" ]
		then
			_tasks="${_tasks} ${_task/\.txt/}"
		fi
	done
	popd > /dev/null
	_tasks="${_tasks/ /}"
	
	echo "${_tasks}"
} # end queue_bash_manager_tasks

# Process the tasks, updating the server from begin to the end.
function queue_bash_worker() {
	# Parameters.
	local _queue="${1}"
	local _task="${2}"
	queue_bash_print "debug" "worker" "queue_bash_worker params: _queue=[${_queue}], _task=[${_task}]]"

	# Extract the hostname.
	local _hostname="${_task//_/.}"
	local _file_run="$(queue_bash_file_running "${_queue}" "${_task}")"
	queue_bash_print "debug" "worker" "Deploying to [${_hostname}]"
	echo "Server: ${_hostname}" >> "${_file_run}"

	# Get the list of packages.
	local _file_task="$(queue_bash_file_task "${_queue}" "${_task}")"
	local _packages="$(cat "${_file_task}")"
	echo "Cloudsource: ${_packages// /, }" >> "${_file_run}"

	# Timestamp the start.
	echo "Start: $(date "+%Y-%m-%d %H:%M:%S")" >> "${_file_run}"

	# Update the packages.
	local _file_log="$(queue_bash_file_log "${_task}")"
	for _package in ${_packages}
	do
		# Update one package at the time.
		queue_bash_print "debug" "worker" "Deploying [${_hostname}] with [${_package}]"
		local _headline="Update ${_hostname} with ${_package}"
		printf "\n${_headline}\n" >> "${_file_log}"
		printf "%${#_headline}s\n" | tr " " "-"  >> "${_file_log}"
		local _ssh_deploy_command="$(printf "${SSH_DEPLOY_COMMAND}" "${_package}" "${_package}")"
		local _retval=""
		if [ "${CONCURRENT_THREAD_ENABLE}" == "yes" ]
		then
			ssh -t -q -o "StrictHostKeyChecking=no" -i "${SSHKEY}" "${BUILD_DEPLOYER}"@"${_hostname}" "${_ssh_deploy_command}" >> "${_file_log}" 2>&1
			_retval="${?}"
		else
			# Print the header.
			printf "%80s\n" | tr " " "="
			cat "${_file_run}"
			printf "%80s\n" | tr " " "-"

			# Execute inline, printing as it deploys.
			set -o pipefail
			ssh -t -q -o "StrictHostKeyChecking=no" -i "${SSHKEY}" "${BUILD_DEPLOYER}"@"${_hostname}" "${_ssh_deploy_command}" | tee "${_file_log}" 2>&1
			_retval="${?}"

			# Print the footer line.
			echo "Retval: ${_retval}"
			printf "%80s\n" | tr " " "="
		fi
		
		queue_bash_print "debug" "worker" "Return value is [${_retval}] for ${_hostname} with ${_package}"
		if [ "${_retval}" -ne "0" ]
		then
			# Finish the deployment process and bubble up the error.
			queue_bash_print "error" "worker" "Job failed to deploy ${_hostname} with ${_package}."
			echo "!!  Error updating ${_hostname} with ${_package}  !!" >> "${_file_log}"

			# Finish and wrap up the logs.
			queue_bash_worker_finish "${_retval}" "${_queue}" "${_task}"

			# Error!
			exit -1
		fi
	done
	queue_bash_print "debug" "worker" "Job finished."

	# Update the running file.
	queue_bash_worker_finish "0" "${_queue}" "${_task}"

	# Finish successfully.
	exit 0
}

# Return the amount of workers running in this queue.
function queue_bash_worker_count() {
	local _queue="${1}"
	ls "${FOLDER_RUNNING}/${_queue}"/*.run 2> /dev/null | wc -l | sed 's/ //g'
} # end queue_bash_worker_count

# Wrapping tasks when they finish.
function queue_bash_worker_finish() {
	# Parameters.
	local _retval="${1}"
	local _queue="${2}"
	local _task="${3}"
	queue_bash_print "debug" "worker" "queue_bash_worker_finish: _retval=[${_retval}], _queue=[${_queue}], _task=[${_task}]"

	# Timestamp the end of process.
	local _file_run="$(queue_bash_file_running "${_queue}" "${_task}")"
	echo "End: $(date "+%Y-%m-%d %H:%M:%S")" >> "${_file_run}"

	# Check the return value for file output.
	local _file_done=""
	if [ "${_retval}" -eq "0" ]
	then
		_file_done="$(queue_bash_file_success "${_task}")"
	else
		_file_done="$(queue_bash_file_fail "${_task}")"
	fi
	queue_bash_print "debug" "worker" "final report file: _file_done=[${_file_done}]"

	# Save the retval value.
	local _file_log="$(queue_bash_file_log "${_task}")"
	printf "%80s\n" | tr " " "="  > "${_file_done}"
	echo "Retval: ${_retval}"    >> "${_file_done}"
	cat "${_file_run}"           >> "${_file_done}"
	printf "%80s\n" | tr " " "-" >> "${_file_done}"
	cat "${_file_log}"           >> "${_file_done}"
	printf "%80s\n" | tr " " "=" >> "${_file_done}"

	# Print the whole logs into Hudson.
	if [ "${CONCURRENT_THREAD_ENABLE}" == "yes" ]
	then
		cat "${_file_done}"
	fi

	# Remove the running file.
	local _file_task="$(queue_bash_file_task "${_queue}" "${_task}")"
	rm -f "${_file_run}" "${_file_task}" "${_file_log}" 
	local _retval="${?}"
	if [ "${_retval}" -ne "0" ]
	then
		# Not able to remove the run file. Something really bad happened. Should I commit sepuku?
		queue_bash_print "error" "worker" "Error deleting the file ${_file_run} which will hold everything back."

		# Leeroy Jenkins!!!
		echo kill -9 $$
	fi
}

# Basic arguments validation.
if [ "${#}" -ne "4" ]
then
	queue_bash_print "error" "core" "Invalid number of arguments"
	queue_bash_help
elif ! [[ "${4}" =~ ^[0-9]+$ ]]
then
	queue_bash_print "error" "core" "Queue size must be a number"
	queue_bash_help
fi

# Load variables
BUILD_INSTANCES="${1//,/ }"
BUILD_ROLES="${2}"
BUILD_DEPLOYER="${3}"
BUILD_QUEUE_SIZE="${4}"

# Clean up previous execution.
queue_bash_startup

# For each datacenter and tier
# - create a new folder under queues with ${tier}-${datacenter}.
# - create a file with the list of roles, one per line.
queue_bash_print "info" "core" "Create tasks"
queue_bash_core_tasks "${BUILD_INSTANCES}" "${BUILD_ROLES}"

# Create the queues managers to process the tasks.
queue_bash_print "info" "core" "Create Queues Managers"
queue_bash_core_queues "${BUILD_QUEUE_SIZE}" "${BUILD_DEPLOYER}"

# Wait for the jobs to finish.
queue_bash_print "info" "core" "Wait for the queue managers to finish"
_fail="0"
for _job in $(jobs -p)
do
	wait ${_job} || let "_fail = ${_fail} + 1"
done

# Check for errors.
if [ "${_fail}" -ne "0" ]
then
	queue_bash_print "error" "core" "${_fail} queues managers finished with errors"
	exit -1
fi
queue_bash_print "info" "core" "Run succesful"
exit 0