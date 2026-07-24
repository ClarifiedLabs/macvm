package dockercompat

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	tcexec "github.com/testcontainers/testcontainers-go/exec"
	"github.com/testcontainers/testcontainers-go/network"
	"github.com/testcontainers/testcontainers-go/wait"
)

func TestContainerConsumerWorkflow(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	runLabel := os.Getenv("MACVM_DOCKER_COMPAT_LABEL")
	labels := map[string]string{"dev.macvm.docker-compat.run": runLabel}
	compatNetwork, err := network.New(ctx)
	if err != nil {
		t.Fatalf("create network: %v", err)
	}
	t.Cleanup(func() {
		if err := compatNetwork.Remove(context.Background()); err != nil {
			t.Errorf("remove network: %v", err)
		}
	})

	server, err := testcontainers.Run(
		ctx,
		"nginx:1.29-alpine",
		testcontainers.WithExposedPorts("80/tcp"),
		testcontainers.WithLabels(labels),
		network.WithNetwork([]string{"compat-web"}, compatNetwork),
		testcontainers.WithWaitStrategy(
			wait.ForHTTP("/").WithPort("80/tcp").WithStartupTimeout(2*time.Minute),
		),
	)
	if err != nil {
		t.Fatalf("start server: %v", err)
	}
	testcontainers.CleanupContainer(t, server)

	host, err := server.Host(ctx)
	if err != nil {
		t.Fatalf("resolve server host: %v", err)
	}
	port, err := server.MappedPort(ctx, "80/tcp")
	if err != nil {
		t.Fatalf("resolve mapped port: %v", err)
	}
	response, err := http.Get(fmt.Sprintf("http://%s:%s/", host, port.Port()))
	if err != nil {
		t.Fatalf("request published port: %v", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), "Welcome to nginx") {
		t.Fatalf("unexpected response: status=%d body=%q", response.StatusCode, body)
	}

	exitCode, output, err := server.Exec(
		ctx,
		[]string{"sh", "-c", "printf exec-marker"},
		tcexec.Multiplexed(),
	)
	if err != nil {
		t.Fatalf("exec in server: %v", err)
	}
	execOutput, err := io.ReadAll(output)
	if err != nil {
		t.Fatalf("read exec output: %v", err)
	}
	if exitCode != 0 || string(execOutput) != "exec-marker" {
		t.Fatalf("unexpected exec result: exit=%d output=%q", exitCode, execOutput)
	}

	client, err := testcontainers.Run(
		ctx,
		"alpine:3.23",
		testcontainers.WithLabels(labels),
		network.WithNetwork([]string{"compat-client"}, compatNetwork),
		testcontainers.WithCmd("sleep", "300"),
	)
	if err != nil {
		t.Fatalf("start client: %v", err)
	}
	testcontainers.CleanupContainer(t, client)

	exitCode, output, err = client.Exec(
		ctx,
		[]string{"wget", "-qO-", "http://compat-web"},
		tcexec.Multiplexed(),
	)
	if err != nil {
		t.Fatalf("request server by network alias: %v", err)
	}
	networkOutput, err := io.ReadAll(output)
	if err != nil {
		t.Fatalf("read network output: %v", err)
	}
	if exitCode != 0 || !strings.Contains(string(networkOutput), "Welcome to nginx") {
		t.Fatalf("unexpected network response: exit=%d output=%q", exitCode, networkOutput)
	}

	logs, err := server.Logs(ctx)
	if err != nil {
		t.Fatalf("read logs: %v", err)
	}
	defer logs.Close()
	if _, err := io.Copy(io.Discard, logs); err != nil {
		t.Fatalf("consume logs: %v", err)
	}
}
