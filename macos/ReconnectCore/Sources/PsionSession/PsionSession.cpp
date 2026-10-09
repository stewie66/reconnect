#include "PsionSession.h"
#include <tcpsocket.h>
#include <rpcsfactory.h>
#include <memory>
#include <cstring>

struct PsionCommandSession {
    TCPSocket socket;
    std::unique_ptr<RPCS> commands;
};

PsionCommandSession *psion_session_open(const char *host, int32_t port) {
    auto session = std::make_unique<PsionCommandSession>();
    if (!session->socket.connect(host, port)) return nullptr;
    RPCSFactory factory(&session->socket);
    session->commands.reset(factory.create(false));
    if (!session->commands) return nullptr;
    return session.release();
}

void psion_session_close(PsionCommandSession *session) { delete session; }

int32_t psion_file_owner(PsionCommandSession *session, const char *path, char *owner, size_t capacity) {
    if (!capacity) return RFSV::E_PSI_GEN_FAIL;
    std::memset(owner, 0, capacity);
    return session->commands->fuser(path, owner, static_cast<int>(capacity)).value;
}

int32_t psion_program_running(PsionCommandSession *session, const char *process) {
    return session->commands->queryProgram(process).value;
}

int32_t psion_stop_program(PsionCommandSession *session, const char *process) {
    return session->commands->stopProgram(process).value;
}

int32_t psion_program_details(PsionCommandSession *session, const char *process, char *executable, size_t capacity) {
    // fuser supplies the exact process ID. Query it directly: upstream getProcId()
    // returns a dangling pointer, so never use process-list helpers here.
    std::string command;
    auto result = session->commands->getCmdLine(process, command);
    if (result != RFSV::E_PSI_GEN_NONE) return result.value;
    if (command.empty() || command.size() >= capacity) return RFSV::E_PSI_GEN_FAIL;
    std::memset(executable, 0, capacity);
    std::memcpy(executable, command.c_str(), command.size());
    return RFSV::E_PSI_GEN_NONE;
}
