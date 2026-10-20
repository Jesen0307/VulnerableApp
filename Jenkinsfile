pipeline {
    agent any

    environment {
        REPORTS_DIR = 'security-reports'
        SONAR_HOST_URL = 'http://sonarqube:9000'
        PATH = "/opt/sonar-scanner/bin:${env.PATH}"
        SONAR_TOKEN = 'squ_a76c5e818a392cb07370af0fb874c9e3fe84ec90'
        SONAR_PROJECT_KEY = 'VulnerableApp'
    }

    stages {
        stage('Install Dependencies') {
            steps {
                sh '''
                    sudo apt-get update
                    sudo apt-get install -y python3 python3-pip python3-venv curl unzip docker.io default-jdk

                    if [ ! -d "/usr/lib/jvm/java-17-temurin" ]; then
                        sudo mkdir -p /usr/lib/jvm/java-17-temurin
                        curl -sL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" | sudo tar -xz -C /usr/lib/jvm/java-17-temurin --strip-components=1
                    fi

                    SONAR_SCANNER_VERSION=8.1.0.6389
                    if [ ! -x /opt/sonar-scanner/bin/sonar-scanner ]; then
                        sudo mkdir -p /opt/sonar-scanner
                        curl -fsSL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" -o /tmp/sonar-scanner.zip
                        sudo unzip -q /tmp/sonar-scanner.zip -d /tmp/sonar-scanner-install
                        sudo cp -r /tmp/sonar-scanner-install/sonar-scanner-*/. /opt/sonar-scanner/
                        sudo chmod -R +x /opt/sonar-scanner/bin /opt/sonar-scanner/jre/bin
                        rm -rf /tmp/sonar-scanner.zip /tmp/sonar-scanner-install
                    fi

                    # Install OpenCode CLI (required by the aiAgent step)
                    if ! command -v opencode >/dev/null 2>&1; then
                        sudo apt-get install -y nodejs npm
                        sudo npm install -g opencode-ai
                    fi
                    opencode --version
                '''
            }
        }

        stage('Build (Compile Java)') {
            steps {
                sh 'chmod +x gradlew'
                sh './gradlew classes printRuntimeClasspath --no-daemon'
            }
        }

        stage('SAST (SonarQube)') {
            steps {
                sh 'mkdir -p $REPORTS_DIR'
                sh 'chmod +x scripts/sonarqube-scan.sh'
                sh './scripts/sonarqube-scan.sh . $SONAR_PROJECT_KEY $SONAR_HOST_URL $SONAR_TOKEN $REPORTS_DIR'
            }
        }
    }

    post {
        always {
            echo 'Pipeline execution completed. Archiving SonarQube report for remediation agent...'
            archiveArtifacts artifacts: "${env.REPORTS_DIR}/sonar_raw.json", allowEmptyArchive: true

            aiAgent agent: openCode(),
                    apiCredentialsId: 'OpenCode',
                    approvalTimeoutSeconds: 1,
                    failOnAgentError: false,
                    model: 'opencode/deepseek-v4.1-flash-free',
                    prompt: "Review this project and summarize it. Use the findings in ${env.REPORTS_DIR}/sonar_raw.json as context.",
                    yoloMode: true
        }
    }
}
