#include "mpc_slave_channel.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <variant>

namespace {

constexpr char kChannelName[] = "streamlink_gui/mpc_slave";

// An integer argument, whichever width the codec chose for it: command ids
// from 0x80000000 up arrive as int64.
std::optional<int64_t> GetInteger(const flutter::EncodableMap& args,
                                  const char* key) {
  const auto found = args.find(flutter::EncodableValue(key));
  if (found == args.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&found->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&found->second)) {
    return *value;
  }
  return std::nullopt;
}

std::string GetString(const flutter::EncodableMap& args, const char* key) {
  const auto found = args.find(flutter::EncodableValue(key));
  if (found == args.end()) {
    return std::string();
  }
  const auto* value = std::get_if<std::string>(&found->second);
  return value != nullptr ? *value : std::string();
}

}  // namespace

MpcSlaveChannel::MpcSlaveChannel(flutter::BinaryMessenger* messenger)
    : channel_(
          std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
              messenger, kChannelName,
              &flutter::StandardMethodCodec::GetInstance())) {
  sessions_ = std::make_unique<mpc_slave::Sessions>(
      [this](const mpc_slave::Event& event) {
        channel_->InvokeMethod(
            "event",
            std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                {flutter::EncodableValue("session"),
                 flutter::EncodableValue(event.session)},
                {flutter::EncodableValue("command"),
                 flutter::EncodableValue(static_cast<int64_t>(event.command))},
                {flutter::EncodableValue("payload"),
                 flutter::EncodableValue(mpc_slave::ToUtf8(event.payload))},
            }));
      },
      [this](const mpc_slave::Rejection& rejection) {
        channel_->InvokeMethod(
            "rejected",
            std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                {flutter::EncodableValue("session"),
                 flutter::EncodableValue(rejection.session)},
                {flutter::EncodableValue("pid"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(rejection.sender_pid))},
                {flutter::EncodableValue("command"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(rejection.command))},
            }));
      });
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleCall(call, std::move(result)); });
}

MpcSlaveChannel::~MpcSlaveChannel() {
  // No more calls in; then every session closed while the channel can still
  // answer the sends that were waiting.
  channel_->SetMethodCallHandler(nullptr);
  sessions_.reset();
}

void MpcSlaveChannel::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap none;
  const flutter::EncodableMap& arguments = args != nullptr ? *args : none;
  const int session =
      static_cast<int>(GetInteger(arguments, "session").value_or(0));

  if (method == "open") {
    const int opened = sessions_->Open();
    if (opened == 0) {
      result->Error("unavailable",
                    "Could not create the player's control window.");
      return;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("session"), flutter::EncodableValue(opened)},
        {flutter::EncodableValue("window"),
         flutter::EncodableValue(mpc_slave::ToUtf8(
             mpc_slave::FormatWindowHandle(sessions_->WindowOf(opened))))},
    }));
  } else if (method == "bind") {
    const int64_t pid = GetInteger(arguments, "pid").value_or(0);
    const bool bound =
        pid > 0 && pid <= MAXDWORD &&
        sessions_->Bind(session, static_cast<DWORD>(pid));
    result->Success(flutter::EncodableValue(bound));
  } else if (method == "send") {
    const int64_t command = GetInteger(arguments, "command").value_or(0);
    // Shared: the reply can come later, from the dispatch window.
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply =
        std::move(result);
    sessions_->Send(session, static_cast<ULONG_PTR>(command),
                    mpc_slave::FromUtf8(GetString(arguments, "payload")),
                    [reply](bool delivered) {
                      reply->Success(flutter::EncodableValue(delivered));
                    });
  } else if (method == "close") {
    sessions_->Close(session);
    result->Success();
  } else {
    result->NotImplemented();
  }
}
