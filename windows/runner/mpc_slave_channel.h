#ifndef RUNNER_MPC_SLAVE_CHANNEL_H_
#define RUNNER_MPC_SLAVE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

#include "mpc_slave.h"

// "streamlink_gui/mpc_slave": the Dart side of mpc_slave::Sessions (see
// lib/services/mpc_slave.dart).
//
// Dart -> native:
//   open                        -> {session: int, window: String}, the window
//                                  in the form "/slave" takes
//   bind  {session, pid}        -> bool
//   send  {session, command,    -> bool, once the player has answered (or
//          payload: String}        not)
//   close {session}             -> null
// Native -> Dart, no reply read:
//   event    {session, command, payload: String}
//   rejected {session, pid, command}
class MpcSlaveChannel {
 public:
  explicit MpcSlaveChannel(flutter::BinaryMessenger* messenger);
  ~MpcSlaveChannel();

  MpcSlaveChannel(const MpcSlaveChannel&) = delete;
  MpcSlaveChannel& operator=(const MpcSlaveChannel&) = delete;

 private:
  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Declared before sessions_, so it is destroyed after it: closing the
  // sessions answers the sends still waiting, through this channel.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<mpc_slave::Sessions> sessions_;
};

#endif  // RUNNER_MPC_SLAVE_CHANNEL_H_
