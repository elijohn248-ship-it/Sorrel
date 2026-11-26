#include "ui/update/update_host.h"
#include "core/codec.h"
#include "platform/platform.h"
#include "include/cef_task.h"
#include <atomic>
#include <thread>
#include <mutex>
#if defined(__linux__)
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;
#endif
namespace birch::ui {
namespace {
class Tick : public CefTask {
 public:
  explicit Tick(std::function<void()> fn):fn_(std::move(fn)) {}
  void Execute() override {fn_();}
 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(Tick);
};
}
struct UpdateHost::Job {
  std::atomic<bool> done{false},cancel{false};
  int pid=0;
  std::mutex process_lock;
  std::string result;
};
UpdateHost::UpdateHost(std::function<void()> changed):changed_(std::move(changed)),
    life_(std::make_shared<Life>(Life{this})) {
#if defined(__linux__)
  helper_=core::JoinPath(platform::ExecutableDir(),"linux-updater.py");
  supported_=core::FileExists(helper_) && core::FileExists(
    core::JoinPath(platform::ExecutableDir(),"update-config.json"));
#endif
  status_={{"supported",supported_},{"status","idle"},{"message","Linux test updates"},
           {"version",""},{"build",0},{"canInstall",false},{"busy",false}};
}
UpdateHost::~UpdateHost() {CancelCheck();life_->owner=nullptr;}
void UpdateHost::Check() {Start("check");}
void UpdateHost::Install() {
  if(status_.value("canInstall",false)) Start("install");
}
void UpdateHost::CancelCheck() {
#if defined(__linux__)
  if(job_ && busy_ && operation_=="check") {
    job_->cancel=true;
    std::lock_guard<std::mutex> guard(job_->process_lock);
    if(job_->pid>0) kill(job_->pid,SIGTERM);
  }
#endif
}
void UpdateHost::Start(const std::string& operation) {
  if(!supported_ || busy_) return;
  operation_=operation;busy_=true;job_=std::make_shared<Job>();
  status_["status"]=operation=="check"?"checking":"installing";
  status_["busy"]=true;
  status_["message"]=operation=="check"?"Checking for Linux test updates…":
    "Downloading and verifying the update. Approve the system installation prompt when it appears.";
  changed_();
#if defined(__linux__)
  auto job=job_;auto helper=helper_;
  std::thread([job,helper,operation] {
    int pipefd[2];
    if(pipe2(pipefd,O_CLOEXEC)!=0) {job->done=true;return;}
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions,pipefd[1],STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions,pipefd[0]);
    posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0);
    const char* args[]={"/usr/bin/python3","-I",helper.c_str(),operation.c_str(),nullptr};
    pid_t pid=0;
    int spawned=posix_spawn(&pid,args[0],&actions,nullptr,const_cast<char* const*>(args),environ);
    posix_spawn_file_actions_destroy(&actions);close(pipefd[1]);
    if(spawned==0) {
      {std::lock_guard<std::mutex> guard(job->process_lock);
       job->pid=pid;if(job->cancel) kill(pid,SIGTERM); }
      char buffer[2048];ssize_t count;
      while((count=read(pipefd[0],buffer,sizeof buffer))>0) {
        if(job->result.size()+static_cast<size_t>(count)>16384) {kill(pid,SIGTERM);job->result.clear();break;}
        job->result.append(buffer,static_cast<size_t>(count));
      }
      // Observe exit without releasing the PID. Cancellation and reaping
      // share a lock so a stale PID can never signal an unrelated process.
      siginfo_t info{};
      while(waitid(P_PID,static_cast<id_t>(pid),&info,WEXITED|WNOWAIT)<0 && errno==EINTR) {}
      int status=0;
      {std::lock_guard<std::mutex> guard(job->process_lock);
       job->pid=0;while(waitpid(pid,&status,0)<0 && errno==EINTR) {} }
      if(!WIFEXITED(status) || WEXITSTATUS(status)!=0) job->result.clear();
    }
    close(pipefd[0]);job->done=true;
  }).detach();
#else
  job_->done=true;
#endif
  Poll();
}
void UpdateHost::Poll() {
  if(job_->done) {
    core::Json next;
    if(!core::ParseJson(job_->result,&next) || !next.is_object() ||
       !next.contains("status") || !next["status"].is_string() ||
       !next.contains("message") || !next["message"].is_string() ||
       !next.contains("canInstall") || !next["canInstall"].is_boolean()) {
      next={{"status","error"},{"message","The update check could not finish."},{"canInstall",false}};
    }
    status_=std::move(next);status_["supported"]=supported_;status_["busy"]=false;
    busy_=false;changed_();return;
  }
  std::weak_ptr<Life> weak=life_;
  CefPostDelayedTask(TID_UI,new Tick([weak] {
    if(auto live=weak.lock();live && live->owner) live->owner->Poll();
  }),100);
}
}
